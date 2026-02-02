import express from 'express';
import pool from '../db.js';
import { requireAuth } from '../middleware/auth.js';

const router = express.Router();

// All routes require auth
router.use(requireAuth);

/**
 * GET /v1/content-items
 * List content items with status filter
 */
router.get('/', async (req, res) => {
  try {
    const { status } = req.query;
    let query = 'SELECT * FROM content_items WHERE product_id = $1';
    const params = [req.productId];

    if (status) {
      query += ' AND status = $2';
      params.push(status);
    }

    query += ' ORDER BY created_at DESC';

    const result = await pool.query(query, params);
    res.json({ items: result.rows });
  } catch (error) {
    console.error('List content error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * GET /v1/content-items/:id
 * Get content item details
 */
router.get('/:id', async (req, res) => {
  try {
    const { id } = req.params;

    const result = await pool.query(
      'SELECT * FROM content_items WHERE id = $1 AND product_id = $2',
      [id, req.productId]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Content item not found' });
    }

    res.json({ item: result.rows[0] });
  } catch (error) {
    console.error('Get content error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * PATCH /v1/content-items/:id/variants/:variantId
 * Edit a content variant (only when not published)
 */
router.patch('/:id/variants/:variantId', async (req, res) => {
  try {
    const { id, variantId } = req.params;
    const { content } = req.body;

    if (!content) {
      return res.status(400).json({ error: 'Content required' });
    }

    // Get current item
    const itemResult = await pool.query(
      'SELECT * FROM content_items WHERE id = $1 AND product_id = $2',
      [id, req.productId]
    );

    if (itemResult.rows.length === 0) {
      return res.status(404).json({ error: 'Content item not found' });
    }

    const item = itemResult.rows[0];

    if (item.status === 'published') {
      return res.status(400).json({ error: 'Cannot edit published content' });
    }

    // Update variant in variants array
    const variants = item.variants || [];
    const variantIndex = variants.findIndex(v => v.id === variantId);
    
    if (variantIndex === -1) {
      return res.status(404).json({ error: 'Variant not found' });
    }

    const oldVariant = { ...variants[variantIndex] };
    variants[variantIndex] = { ...variants[variantIndex], content };

    await pool.query(
      'UPDATE content_items SET variants = $1, updated_at = NOW() WHERE id = $2',
      [JSON.stringify(variants), id]
    );

    // Audit log
    await pool.query(
      `INSERT INTO content_audit_log (content_item_id, user_id, action, variant_id, old_value, new_value)
       VALUES ($1, $2, 'edit_variant', $3, $4, $5)`,
      [id, req.userId, variantId, JSON.stringify(oldVariant), JSON.stringify(variants[variantIndex])]
    );

    res.json({ message: 'Variant updated', variant: variants[variantIndex] });
  } catch (error) {
    console.error('Edit variant error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * POST /v1/content-items/:id/approve
 */
router.post('/:id/approve', async (req, res) => {
  try {
    const { id } = req.params;

    await pool.query(
      'UPDATE content_items SET status = $1, updated_at = NOW() WHERE id = $2 AND product_id = $3',
      ['approved', id, req.productId]
    );

    await pool.query(
      'INSERT INTO content_audit_log (content_item_id, user_id, action) VALUES ($1, $2, $3)',
      [id, req.userId, 'approve']
    );

    res.json({ message: 'Content approved' });
  } catch (error) {
    console.error('Approve error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * POST /v1/content-items/:id/reject
 */
router.post('/:id/reject', async (req, res) => {
  try {
    const { id } = req.params;

    await pool.query(
      'UPDATE content_items SET status = $1, updated_at = NOW() WHERE id = $2 AND product_id = $3',
      ['rejected', id, req.productId]
    );

    await pool.query(
      'INSERT INTO content_audit_log (content_item_id, user_id, action) VALUES ($1, $2, $3)',
      [id, req.userId, 'reject']
    );

    res.json({ message: 'Content rejected' });
  } catch (error) {
    console.error('Reject error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

export default router;

