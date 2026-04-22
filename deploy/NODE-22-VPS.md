# Node 22 na VPS (paralelo ao Node 18 do fifty)

Objetivo: ter **`/opt/node22/bin/node`** (versao LTS 22.x) para **build e PM2 do BellX**, sem alterar o `node` que o **fifty** usa (hoje **18.20.4** em `/usr/bin` ou equivalente).

## 0) So leitura — estado antes

```bash
command -v node; node -v
readlink -f "$(command -v node)" 2>/dev/null || true
pm2 describe fifty_api | sed -n '1,20p'
```

Nao mudes nada aqui; e a linha de base.

## 1) Instalar Node 22 em `/opt` (recomendado; nao mexe no apt do Node 18)

Escolhe a versao patch em https://nodejs.org/dist/ (ex.: `v22.15.0`). Depois:

```bash
NODE_VER=v22.15.0
cd /opt
sudo curl -fsSLO "https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-linux-x64.tar.xz"
sudo tar -xJf "node-${NODE_VER}-linux-x64.tar.xz"
sudo rm -rf /opt/node22
sudo mv "node-${NODE_VER}-linux-x64" /opt/node22
sudo rm -f "node-${NODE_VER}-linux-x64.tar.xz"
```

Verificar:

```bash
/opt/node22/bin/node -v
/opt/node22/bin/npm -v
node -v
```

O ultimo `node -v` deve continuar **v18.x** se o PATH nao foi alterado.

## 2) Build do BellX com Node 22 (quando o repo estiver pronto na VM)

```bash
cd /root/belagarota_api/bellXback
/opt/node22/bin/npm ci
/opt/node22/bin/npm run build
```

O PM2 do BellX deve usar `interpreter: '/opt/node22/bin/node'` e `script: 'dist/index.js'` (definido mais tarde no ecosystem).

## 3) O que evitar nesta fase

- **Nao** corras `curl ... nodesource.com/setup_22.x | bash` + `apt install nodejs` se isso **substituir** o pacote Node do sistema onde o fifty depende do 18.
- **Nao** alteres o processo `fifty_api` no PM2 nesta fase.

## 4) Alternativa: NVM (da sim)

Funciona bem desde que o **PM2 do BellX** use o **caminho absoluto** do `node` do NVM, nao a palavra `node` sozinha.

### Instalacao (utilizador root, exemplo)

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
source ~/.bashrc
nvm install 22
nvm use 22
which node
node -v
```

Descobre o path fixo (para colar no PM2 `interpreter`):

```bash
readlink -f "$(command -v node)"
# ex.: /root/.nvm/versions/node/v22.15.0/bin/node
```

Confirma que **outra shell sem `nvm use`** ainda ve o 18:

```bash
bash -lc 'command -v node; node -v'
```

### Cuidados

| Cuidado | Porque |
|---------|--------|
| **`interpreter` no PM2 = path absoluto** | O daemon PM2 **nao** carrega `~/.bashrc`; `nvm` nao existe nesse contexto. |
| **Nao fazer `nvm alias default 22`** se quiseres que shells novos continuem a ver o 18 por defeito — ou faz e garante que o **fifty** no PM2 ja usa `interpreter` absoluto para o 18 (hoje usa `node` = o que estiver primeiro no PATH no **restart**). Mais simples: **deixa `default` do nvm em 22** *so depois* de o fifty ter `interpreter: /usr/bin/node` (ou path do 18) fixo no ecosystem. |
| **Backup antes de mudar default** | `pm2 describe fifty_api` e anota o `exec_interpreter`. |

### PM2 ecosystem (BellX)

No `pm2.ecosystem.config.cjs`, em vez de `NODE22 = "/opt/node22/bin/node"`, usa por exemplo:

```js
const NODE22 = "/root/.nvm/versions/node/v22.15.0/bin/node"; // ajusta ao teu `readlink -f`
```

O fifty **nao** precisa de NVM se continuar com o binario do sistema 18.
