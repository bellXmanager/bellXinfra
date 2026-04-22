# Deploy BellX na VPS (PM2 + Nginx)

Nao ha ficheiros PM2/Nginx dentro de `bellXback` ou `bellXfront`; este diretorio e a referencia **plug-and-play** para alinhar com a VM (Hostinger + fifty na mesma maquina).

## Ficheiros

| Ficheiro | Uso |
|----------|-----|
| [**NODE-22-VPS.md**](./NODE-22-VPS.md) | Instalar Node **22** em `/opt/node22` sem estragar o Node **18** do fifty. |
| [`pm2.ecosystem.config.cjs`](./pm2.ecosystem.config.cjs) | Processos `bellx-api` (porta **3050**) e `bellx-web` (Next `start` na **3002** interna). |
| [`nginx-belagarotavip.conf.example`](./nginx-belagarotavip.conf.example) | `api.belagarotavip.com` -> 3050; `belagarotavip.com` / `www` -> 3002. |

## Portas (evitar conflito com fifty)

| Servico | Porta interna (Node) |
|---------|----------------------|
| fifty API (existente) | tipicamente **3000** |
| **bellX API** | **3050** |
| **bellX Next (producao)** | **3002** (exemplo; muda se estiver ocupada) |
| bellX Next dev no laptop | **3001** (`next dev -p 3001`) |

## Checklist na VM

1. **Node** >= 22, **PM2** global (`npm i -g pm2`), **Nginx**.
2. Clonar ou sincronizar `bellXback` e `bellXfront` para o path definido em `ROOT` no `pm2.ecosystem.config.cjs`.
3. **bellXback:** `npm ci && npm run build` — ficheiro `.env` na raiz do back com `PORT=3050`, AWS, Mongo, Redis, etc.
4. **bellXfront:** criar `.env.production` (ou o nome que usares no `env_file` do ecosystem) com `NEXT_PUBLIC_BELLX_BACKEND_URL=https://api.belagarotavip.com` e o resto; depois `npm ci && npm run build`.
5. **PM2:** `cd .../bellXinfra/deploy && pm2 start pm2.ecosystem.config.cjs` — ver `pm2 logs bellx-api` / `bellx-web`.
6. **Nginx:** copiar o exemplo para `sites-available`, descomentar `ssl_certificate`, `nginx -t`, `systemctl reload nginx`.
7. **Firewall:** 80/443 abertos; **nao** expor 3050/3002 publicamente se o Nginx estiver na mesma maquina.

## PM2 `env_file`

Recomendado **PM2 >= 5.3**. Se `env_file` falhar, exporta variaveis no shell antes do `pm2 start` ou usa `dotenv` so no back (ja usa em dev; em prod o Node nao carrega `.env` automaticamente — o PM2 `env_file` ou variaveis no ecosystem resolvem).

## Verificacao rapida

```bash
curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:3050/health
curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:3002/
```

Esperado: `200` (ou 307/308 se o Next redirecionar).

## O que nao da para validar daqui

O Cursor **nao** ve a tua VM: copia o ecosystem e o nginx para o servidor, ajusta `ROOT`, certificados e paths, e corre `nginx -t` + `pm2 list` no SSH.
