/**
 * PM2 — BellX (fifty2) na VPS (ex.: Hostinger).
 *
 * 1. Ajusta `cwd` aos paths reais no servidor.
 * 2. Garante `.env` em cada cwd (nao commitar).
 * 3. bellXback: `npm ci && npm run build` antes do primeiro start.
 * 4. bellXfront: `npm ci && npm run build` antes do primeiro start.
 *
 * Uso:
 *   pm2 start pm2.ecosystem.config.cjs
 *   pm2 save && pm2 startup
 *
 * Requer PM2 >= 5.3 para `env_file` (senao exporta variaveis no shell ou usa dotenv no codigo).
 *
 * Node 22 em paralelo ao fifty (18): ver deploy/NODE-22-VPS.md — usa interpreter absoluto abaixo.
 */
const path = require("path");

// Path real na VPS (ex. Hostinger): /root/belagarota_api/bellXback
const ROOT = "/root/belagarota_api";

/** Binario Node 22 apos instalacao em /opt (NODE-22-VPS.md). O fifty_api continua com `node` = 18. */
const NODE22 = "/opt/node22/bin/node";

module.exports = {
  apps: [
    {
      name: "bellx-api",
      cwd: path.join(ROOT, "bellXback"),
      script: "dist/index.js",
      interpreter: NODE22,
      interpreter_args: "",
      instances: 1,
      exec_mode: "fork",
      autorestart: true,
      watch: false,
      max_memory_restart: "450M",
      env: {
        NODE_ENV: "production",
        PORT: "3050",
      },
      env_file: ".env",
    },
    {
      name: "bellx-web",
      cwd: path.join(ROOT, "bellXfront"),
      script: "node_modules/next/dist/bin/next",
      args: "start -p 3002",
      interpreter: NODE22,
      instances: 1,
      exec_mode: "fork",
      autorestart: true,
      watch: false,
      max_memory_restart: "800M",
      env: {
        NODE_ENV: "production",
      },
      env_file: ".env.production",
    },
  ],
};
