import pool from '../db.js';
import crypto from 'crypto';

/**
 * Middleware to authenticate requests via session cookie
 * Sets req.user and req.productId if valid session
 */
export async function requireAuth(req, res, next) {
  try {
    const sessionToken = req.cookies?.session_token;
    
    if (!sessionToken) {
      return res.status(401).json({ error: 'Unauthorized' });
    }

    // Hash the token to look up in DB
    const tokenHash = crypto
      .createHash('sha256')
      .update(sessionToken)
      .digest('hex');

    // Find valid session
    const result = await pool.query(
      `SELECT s.user_id, s.product_id, s.expires_at, u.email
       FROM sessions s
       JOIN users u ON u.id = s.user_id
       WHERE s.token_hash = $1 
         AND s.revoked_at IS NULL 
         AND s.expires_at > NOW()`,
      [tokenHash]
    );

    if (result.rows.length === 0) {
      return res.status(401).json({ error: 'Invalid or expired session' });
    }

    const session = result.rows[0];
    req.userId = session.user_id;
    req.productId = session.product_id;
    req.userEmail = session.email;

    next();
  } catch (error) {
    console.error('Auth middleware error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
}

