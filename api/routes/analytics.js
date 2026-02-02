import express from 'express';
import pool from '../db.js';
import crypto from 'crypto';
import { requireAuth } from '../middleware/auth.js';

const router = express.Router();

/**
 * POST /v1/analytics/events
 * Accept analytics events via API key OR analytics token
 */
router.post('/events', async (req, res) => {
  try {
    let productId = null;

    // Check for API key (existing auth method)
    const apiKey = req.headers['x-api-key'];
    if (apiKey) {
      // In real app, look up product by API key
      // For MVP, assume it's valid and extract product_id from somewhere
      // This is a placeholder
      productId = req.body.product_id; // Would come from API key lookup
    }

    // Check for analytics token
    const analyticsToken = req.headers['x-analytics-token'];
    if (analyticsToken && !productId) {
      const tokenHash = crypto.createHash('sha256').update(analyticsToken).digest('hex');
      const result = await pool.query(
        `SELECT product_id FROM analytics_tokens 
         WHERE token_hash = $1 AND revoked_at IS NULL`,
        [tokenHash]
      );

      if (result.rows.length > 0) {
        productId = result.rows[0].product_id;
        // Update last used
        await pool.query(
          'UPDATE analytics_tokens SET last_used_at = NOW() WHERE token_hash = $1',
          [tokenHash]
        );
      }
    }

    if (!productId) {
      return res.status(401).json({ error: 'Unauthorized' });
    }

    // Store event (simplified - in real app would have events table)
    // For MVP, just acknowledge receipt
    res.json({ message: 'Event received', product_id: productId });
  } catch (error) {
    console.error('Analytics event error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Protected routes require auth
router.use(requireAuth);

/**
 * GET /v1/analytics/scoreboard
 */
router.get('/scoreboard', async (req, res) => {
  try {
    // Simplified scoreboard - in real app would aggregate from events
    const result = await pool.query(
      `SELECT 
         COUNT(*) FILTER (WHERE status = 'published') as published_count,
         COUNT(*) FILTER (WHERE status = 'approved') as approved_count,
         COUNT(*) FILTER (WHERE status = 'draft') as draft_count
       FROM content_items
       WHERE product_id = $1`,
      [req.productId]
    );

    res.json({ scoreboard: result.rows[0] });
  } catch (error) {
    console.error('Scoreboard error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * POST /v1/analytics/token
 * Generate analytics ingest token (show only once)
 */
router.post('/token', async (req, res) => {
  try {
    // Check if token already exists
    const existing = await pool.query(
      'SELECT id FROM analytics_tokens WHERE product_id = $1 AND revoked_at IS NULL',
      [req.productId]
    );

    if (existing.rows.length > 0) {
      return res.status(409).json({ error: 'Token already exists. Use rotation endpoint.' });
    }

    // Generate token
    const token = crypto.randomBytes(32).toString('hex');
    const tokenHash = crypto.createHash('sha256').update(token).digest('hex');

    await pool.query(
      'INSERT INTO analytics_tokens (product_id, token_hash) VALUES ($1, $2)',
      [req.productId, tokenHash]
    );

    // Return token (only time it's shown in plaintext)
    res.json({ token, message: 'Save this token securely. It will not be shown again.' });
  } catch (error) {
    console.error('Generate token error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * POST /v1/analytics/token/rotate
 * Rotate analytics token
 */
router.post('/token/rotate', async (req, res) => {
  try {
    // Revoke old token
    await pool.query(
      'UPDATE analytics_tokens SET revoked_at = NOW() WHERE product_id = $1 AND revoked_at IS NULL',
      [req.productId]
    );

    // Generate new token
    const token = crypto.randomBytes(32).toString('hex');
    const tokenHash = crypto.createHash('sha256').update(token).digest('hex');

    await pool.query(
      'INSERT INTO analytics_tokens (product_id, token_hash) VALUES ($1, $2)',
      [req.productId, tokenHash]
    );

    res.json({ token, message: 'Token rotated. Save this token securely.' });
  } catch (error) {
    console.error('Rotate token error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

export default router;

