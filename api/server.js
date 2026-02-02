import express from 'express';
import cookieParser from 'cookie-parser';
import cors from 'cors';
import dotenv from 'dotenv';
import authRoutes from './routes/auth.js';
import contentRoutes from './routes/content.js';
import calendarRoutes from './routes/calendar.js';
import analyticsRoutes from './routes/analytics.js';
import settingsRoutes from './routes/settings.js';
import briefsRoutes from './routes/briefs.js';

dotenv.config();

const app = express();
const PORT = process.env.PORT || 3001;

// Middleware
app.use(cors({
  origin: process.env.WEB_URL || 'http://localhost:3000',
  credentials: true,
}));
app.use(express.json());
app.use(cookieParser());

// Health check
app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

// API routes
app.use('/v1/auth', authRoutes);
app.use('/v1/briefs', briefsRoutes);
app.use('/v1/content-items', contentRoutes);
app.use('/v1/calendar', calendarRoutes);
app.use('/v1/analytics', analyticsRoutes);
app.use('/v1/settings', settingsRoutes);

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: 'Not found' });
});

// Error handler
app.use((err, req, res, next) => {
  console.error('Error:', err);
  res.status(500).json({ error: 'Internal server error' });
});

app.listen(PORT, () => {
  console.log(`API server running on port ${PORT}`);
});

