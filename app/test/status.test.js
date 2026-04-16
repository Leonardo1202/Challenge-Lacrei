'use strict';

// Uses Node.js built-in test runner (v20+) — zero extra dependencies
const { test } = require('node:test');
const assert = require('node:assert/strict');
const http   = require('node:http');

process.env.PORT = '3099';
process.env.NODE_ENV = 'test';
process.env.APP_VERSION = 'test-build';

require('../index.js'); // inicia o servidor como efeito colateral

// ── helpers ──────────────────────────────────────────────────────────────────
function get(path) {
  return new Promise((resolve, reject) => {
    const req = http.get(`http://127.0.0.1:3099${path}`, (res) => {
      let body = '';
      res.on('data', chunk => (body += chunk));
      res.on('end', () => resolve({ status: res.statusCode, body }));
    });
    req.on('error', reject);
  });
}

// ── tests ────────────────────────────────────────────────────────────────────
test('GET /status returns 200 with correct shape', async () => {
  const { status, body } = await get('/status');
  assert.equal(status, 200);

  const json = JSON.parse(body);
  assert.equal(json.status,  'ok');
  assert.equal(json.env,     'test');
  assert.equal(json.version, 'test-build');
  assert.ok(json.timestamp,  'timestamp should be present');
});

test('GET /health returns 200', async () => {
  const { status } = await get('/health');
  assert.equal(status, 200);
});

test('GET unknown route returns 404', async () => {
  const { status } = await get('/unknown-path');
  assert.equal(status, 404);
});