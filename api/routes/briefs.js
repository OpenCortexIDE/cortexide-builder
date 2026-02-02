import express from 'express';
import pool from '../db.js';
import { requireAuth } from '../middleware/auth.js';

const router = express.Router();

// All routes require auth
router.use(requireAuth);

/**
 * POST /v1/briefs/:id/enrich
 * Triggers enrichment for a brief
 */
router.post('/:id/enrich', async (req, res) => {
  try {
    const { id } = req.params;

    // Verify brief belongs to user's product
    const briefResult = await pool.query(
      'SELECT id FROM briefs WHERE id = $1 AND product_id = $2',
      [id, req.productId]
    );

    if (briefResult.rows.length === 0) {
      return res.status(404).json({ error: 'Brief not found' });
    }

    // Update brief as enriched (in real app, this would trigger async job)
    await pool.query(
      'UPDATE briefs SET enriched = true, updated_at = NOW() WHERE id = $1',
      [id]
    );

    res.json({ message: 'Enrichment started', brief_id: id });
  } catch (error) {
    console.error('Enrich error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

export default router;

