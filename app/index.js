'use strict';

const express = require('express');
const app = express();

const PORT = process.env.PORT || 3000;
const ENV  = process.env.NODE_ENV || 'development';
const APP_VERSION = process.env.APP_VERSION || 'local';

// ── CORS ────────────────────────────────────────────────────────────────────
const ALLOWED_ORIGINS = (process.env.ALLOWED_ORIGINS || '')
  .split(',')
  .map(o => o.trim())
  .filter(Boolean);

app.use((req, res, next) => {
  const origin = req.headers.origin;
  if (!origin || ALLOWED_ORIGINS.includes(origin) || ALLOWED_ORIGINS.includes('*')) {
    if (origin) res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Access-Control-Allow-Methods', 'GET,OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  }
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

// ── Security headers ─────────────────────────────────────────────────────────
app.use((_req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('X-XSS-Protection', '1; mode=block');
  res.setHeader('Strict-Transport-Security', 'max-age=63072000; includeSubDomains; preload');
  next();
});

// ── Routes ───────────────────────────────────────────────────────────────────
app.get('/status', (_req, res) => {
  res.json({
    status:    'ok',
    env:       ENV,
    version:   APP_VERSION,
    timestamp: new Date().toISOString(),
  });
});

app.get('/health', (_req, res) => res.sendStatus(200));

app.use((_req, res) => res.status(404).json({ error: 'not found' }));

// ── Start ────────────────────────────────────────────────────────────────────
app.listen(PORT, '0.0.0.0', () => {
  console.log(JSON.stringify({
    level:   'info',
    message: 'server started',
    port:    PORT,
    env:     ENV,
    version: APP_VERSION,
  }));
});

module.exports = app; // exported for tests