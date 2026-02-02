import express from 'express';
import bcrypt from 'bcrypt';
import crypto from 'crypto';
import pool from '../db.js';

const router = express.Router();

/**
 * POST /v1/auth/register
 * Creates a new product and first user
 */
router.post('/register', async (req, res) => {
  try {
    const { email, password, productName } = req.body;

    if (!email || !password || !productName) {
      return res.status(400).json({ error: 'Email, password, and product name required' });
    }

    if (password.length < 8) {
      return res.status(400).json({ error: 'Password must be at least 8 characters' });
    }

    // Check if email already exists
    const existingUser = await pool.query('SELECT id FROM users WHERE email = $1', [email]);
    if (existingUser.rows.length > 0) {
      return res.status(409).json({ error: 'Email already registered' });
    }

    // Create product
    const productResult = await pool.query(
      `INSERT INTO products (name) VALUES ($1) RETURNING id`,
      [productName]
    );
    const productId = productResult.rows[0].id;

    // Hash password
    const passwordHash = await bcrypt.hash(password, 10);

    // Create user
    const userResult = await pool.query(
      `INSERT INTO users (product_id, email, password_hash) 
       VALUES ($1, $2, $3) RETURNING id, email, product_id`,
      [productId, email, passwordHash]
    );
    const userId = userResult.rows[0].id;

    // Create session
    const sessionToken = crypto.randomBytes(32).toString('hex');
    const tokenHash = crypto.createHash('sha256').update(sessionToken).digest('hex');
    const expiresAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000); // 30 days

    await pool.query(
      `INSERT INTO sessions (user_id, product_id, token_hash, expires_at)
       VALUES ($1, $2, $3, $4)`,
      [userId, productId, tokenHash, expiresAt]
    );

    // Set httpOnly secure cookie
    res.cookie('session_token', sessionToken, {
      httpOnly: true,
      secure: process.env.NODE_ENV === 'production',
      sameSite: 'strict',
      maxAge: 30 * 24 * 60 * 60 * 1000, // 30 days
    });

    res.status(201).json({
      user: { id: userId, email, product_id: productId },
      product: { id: productId, name: productName },
    });
  } catch (error) {
    console.error('Register error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * POST /v1/auth/login
 */
router.post('/login', async (req, res) => {
  try {
    const { email, password } = req.body;

    if (!email || !password) {
      return res.status(400).json({ error: 'Email and password required' });
    }

    // Find user
    const userResult = await pool.query(
      `SELECT u.id, u.email, u.password_hash, u.product_id, p.name as product_name
       FROM users u
       JOIN products p ON p.id = u.product_id
       WHERE u.email = $1`,
      [email]
    );

    if (userResult.rows.length === 0) {
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    const user = userResult.rows[0];

    // Verify password
    const valid = await bcrypt.compare(password, user.password_hash);
    if (!valid) {
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    // Update last login
    await pool.query('UPDATE users SET last_login_at = NOW() WHERE id = $1', [user.id]);

    // Create session
    const sessionToken = crypto.randomBytes(32).toString('hex');
    const tokenHash = crypto.createHash('sha256').update(sessionToken).digest('hex');
    const expiresAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000); // 30 days

    await pool.query(
      `INSERT INTO sessions (user_id, product_id, token_hash, expires_at)
       VALUES ($1, $2, $3, $4)`,
      [user.id, user.product_id, tokenHash, expiresAt]
    );

    // Set httpOnly secure cookie
    res.cookie('session_token', sessionToken, {
      httpOnly: true,
      secure: process.env.NODE_ENV === 'production',
      sameSite: 'strict',
      maxAge: 30 * 24 * 60 * 60 * 1000,
    });

    res.json({
      user: { id: user.id, email: user.email, product_id: user.product_id },
      product: { id: user.product_id, name: user.product_name },
    });
  } catch (error) {
    console.error('Login error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * POST /v1/auth/logout
 */
router.post('/logout', async (req, res) => {
  try {
    const sessionToken = req.cookies?.session_token;
    
    if (sessionToken) {
      const tokenHash = crypto.createHash('sha256').update(sessionToken).digest('hex');
      await pool.query(
        'UPDATE sessions SET revoked_at = NOW() WHERE token_hash = $1',
        [tokenHash]
      );
    }

    res.clearCookie('session_token');
    res.json({ message: 'Logged out' });
  } catch (error) {
    console.error('Logout error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * GET /v1/auth/me
 * Returns current user info
 */
router.get('/me', async (req, res) => {
  try {
    const sessionToken = req.cookies?.session_token;
    
    if (!sessionToken) {
      return res.status(401).json({ error: 'Unauthorized' });
    }

    const tokenHash = crypto.createHash('sha256').update(sessionToken).digest('hex');
    
    const result = await pool.query(
      `SELECT u.id, u.email, u.product_id, p.name as product_name
       FROM sessions s
       JOIN users u ON u.id = s.user_id
       JOIN products p ON p.id = u.product_id
       WHERE s.token_hash = $1 
         AND s.revoked_at IS NULL 
         AND s.expires_at > NOW()`,
      [tokenHash]
    );

    if (result.rows.length === 0) {
      return res.status(401).json({ error: 'Invalid or expired session' });
    }

    const user = result.rows[0];
    res.json({
      user: { id: user.id, email: user.email, product_id: user.product_id },
      product: { id: user.product_id, name: user.product_name },
    });
  } catch (error) {
    console.error('Me error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

export default router;

