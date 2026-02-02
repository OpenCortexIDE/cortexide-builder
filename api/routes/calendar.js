import express from 'express';
import pool from '../db.js';
import { requireAuth } from '../middleware/auth.js';

const router = express.Router();

router.use(requireAuth);

/**
 * GET /v1/calendar
 * Get 30-day calendar with content items
 */
router.get('/', async (req, res) => {
  try {
    const startDate = new Date();
    const endDate = new Date();
    endDate.setDate(endDate.getDate() + 30);

    const result = await pool.query(
      `SELECT calendar_date, id, status, variants
       FROM content_items
       WHERE product_id = $1 
         AND calendar_date >= $2 
         AND calendar_date <= $3
       ORDER BY calendar_date ASC`,
      [req.productId, startDate, endDate]
    );

    // Group by date
    const calendar = {};
    result.rows.forEach(item => {
      const date = item.calendar_date.toISOString().split('T')[0];
      if (!calendar[date]) {
        calendar[date] = [];
      }
      calendar[date].push({
        id: item.id,
        status: item.status,
        variants: item.variants,
      });
    });

    res.json({ calendar });
  } catch (error) {
    console.error('Calendar error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * POST /v1/calendar/generate-drafts
 * Generate drafts for a calendar item
 */
router.post('/generate-drafts', async (req, res) => {
  try {
    const { calendar_date, brief_id } = req.body;

    if (!calendar_date) {
      return res.status(400).json({ error: 'calendar_date required' });
    }

    // Create content item with draft status
    const result = await pool.query(
      `INSERT INTO content_items (product_id, brief_id, calendar_date, status, variants)
       VALUES ($1, $2, $3, 'draft', '[]'::jsonb)
       RETURNING *`,
      [req.productId, brief_id || null, calendar_date]
    );

    // In real app, this would trigger async job to generate variants
    // For MVP, return the item
    res.json({ item: result.rows[0], message: 'Draft generation started' });
  } catch (error) {
    console.error('Generate drafts error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

export default router;

