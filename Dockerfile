# ── Stage 1: deps ─────────────────────────────────────────────────────────────
FROM node:20-alpine AS deps

WORKDIR /app

# Only copy manifests first — maximises layer cache reuse
COPY app/package.json ./

# Atualiza o pacote 'tar' embutido no npm para corrigir CVEs conhecidos
# (CVE-2026-29786, CVE-2026-31802) antes de instalar as dependências da app
RUN npm install --omit=dev --no-fund --no-audit && \
    npm update tar --no-fund --no-audit && \
    npm cache clean --force

# ── Stage 2: test ─────────────────────────────────────────────────────────────
FROM node:20-alpine AS test

WORKDIR /app

COPY app/package.json ./
RUN npm install --no-fund --no-audit

COPY app/ .

# Run tests — build will fail here if tests do not pass
RUN node --test test/status.test.js

# ── Stage 3: runtime ──────────────────────────────────────────────────────────
FROM node:20-alpine AS runtime

# Non-root user (principle of least privilege)
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

# Copy only production deps + source from previous stages
COPY --from=deps  /app/node_modules ./node_modules
COPY app/index.js .

# Drop all linux capabilities; node only needs to bind a port > 1024
USER appuser

ENV NODE_ENV=production \
    PORT=3000

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["node", "index.js"]