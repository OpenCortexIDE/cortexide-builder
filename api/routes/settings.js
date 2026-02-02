import express from 'express';
import pool from '../db.js';
import { requireAuth } from '../middleware/auth.js';

const router = express.Router();

router.use(requireAuth);

/**
 * GET /v1/settings
 */
router.get('/', async (req, res) => {
  try {
    const result = await pool.query(
      'SELECT * FROM products WHERE id = $1',
      [req.productId]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Product not found' });
    }

    const product = result.rows[0];
    
    // Never expose sensitive data
    const safeProduct = {
      ...product,
      buffer_access_token: product.buffer_access_token ? '[REDACTED]' : null,
    };

    res.json({ settings: safeProduct });
  } catch (error) {
    console.error('Get settings error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * PATCH /v1/settings
 */
router.patch('/', async (req, res) => {
  try {
    const {
      publishing_enabled,
      timezone,
      slack_webhook_url,
      buffer_access_token,
      buffer_profiles,
    } = req.body;

    const updates = [];
    const values = [];
    let paramCount = 1;

    if (publishing_enabled !== undefined) {
      updates.push(`publishing_enabled = $${paramCount++}`);
      values.push(publishing_enabled);
    }

    if (timezone) {
      updates.push(`timezone = $${paramCount++}`);
      values.push(timezone);
    }

    if (slack_webhook_url !== undefined) {
      updates.push(`slack_webhook_url = $${paramCount++}`);
      values.push(slack_webhook_url);
    }

    if (buffer_access_token) {
      // In real app, encrypt this
      updates.push(`buffer_access_token = $${paramCount++}`);
      values.push(buffer_access_token);
    }

    if (buffer_profiles) {
      updates.push(`buffer_profiles = $${paramCount++}`);
      values.push(JSON.stringify(buffer_profiles));
    }

    if (updates.length === 0) {
      return res.status(400).json({ error: 'No updates provided' });
    }

    updates.push(`updated_at = NOW()`);
    values.push(req.productId);

    const query = `UPDATE products SET ${updates.join(', ')} WHERE id = $${paramCount}`;
    await pool.query(query, values);

    res.json({ message: 'Settings updated' });
  } catch (error) {
    console.error('Update settings error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

export default router;

