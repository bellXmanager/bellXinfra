# BellX — permissões via IAM Identity Center (SSO)

Utilizadores criados no **IAM Identity Center** (antigo AWS SSO) **não recebem** `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` de longa duração. O acesso é por **sessão temporária** depois de `aws sso login`, ou pela **consola AWS** com o *permission set* atribuído.

Este guia serve para:

1. Dar ao **Tales** permissão para **CORS e objetos** nos buckets de media BellX (consola + testes).
2. O Tales correr o **bellXback** local com o SDK a assinar presigned URLs **sem** access keys estáticas (`AWS_PROFILE`).

Políticas JSON (ajusta ARNs dos buckets se não forem `*-sae1`):

| Ficheiro | Uso |
|----------|-----|
| [`bellx-developer-s3-media-and-cors.json`](./bellx-developer-s3-media-and-cors.json) | Desenvolvedor (CORS + Put/Get/List/Delete nos buckets de imagem/video) |
| [`bellx-backend-s3-presign.json`](./bellx-backend-s3-presign.json) | Só runtime do API (`s3:PutObject` para presign) — VPS ou pipeline |

---

## A) Consola AWS (S3, CORS) para o utilizador SSO

1. Entra como **administrador** da conta (ou quem gere Identity Center).
2. **IAM Identity Center** → **Permission sets** → **Create permission set** (ou edita um existente só para devs BellX).
3. Tipo **Custom** → em **Permissions policies**, cria política **inline** ou associa uma **customer managed policy** cujo documento é o conteúdo de **`bellx-developer-s3-media-and-cors.json`** (copiar o JSON inteiro).
4. **AWS accounts** → seleciona a conta onde estão os buckets → **Users** ou **Groups** → atribui o *permission set* ao utilizador do **Tales** (ou ao grupo de que ele faz parte).
5. O Tales faz **sign in** no portal SSO da organização e abre a **consola AWS** com esse permission set — deve conseguir ir a **S3** → bucket → **Permissions** → **CORS** e gravar.

Se aparecer *Access Denied* em S3, confirma que o permission set está **provisionado** na conta certa e que os ARNs no JSON batem com os nomes reais dos buckets.

---

## B) Backend local (Node) com SSO — sem access keys

O AWS SDK v3 no `bellXback` usa a **default credential chain**. Com SSO:

1. No PC do Tales: [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) instalado.
2. `aws configure sso` — cria um **named profile** (ex.: `bellx-dev`) com start URL da organização, região, scope da conta, e o *permission set* que inclui pelo menos **`s3:PutObject`** nos buckets (o JSON *developer* já cobre isso + CORS).
3. Sempre que a sessão expirar:

   ```bash
   aws sso login --profile bellx-dev
   ```

4. No `.env` do `bellXback` **não** defines `AWS_ACCESS_KEY_ID` nem `AWS_SECRET_ACCESS_KEY`. Usa:

   ```env
   AWS_REGION=sa-east-1
   AWS_PROFILE=bellx-dev
   ```

5. Arranca o backend (`npm run dev`). O SDK obtém credenciais temporárias via o perfil SSO.

**Nota:** Quem pediu explicitamente "manda as chaves" pode estar habituado a IAM users. Explica que com SSO o fluxo seguro é **perfil + `aws sso login`**, não partilhar secrets estáticos.

---

## C) Conta de serviço do backend na VPS (Hostinger)

Aqui o processo **não** interage com o browser SSO: o normal é um **IAM user** dedicado (ex. `bellx-vps-backend`) com só **`bellx-backend-s3-presign.json`** + access key guardada no servidor (systemd, Docker secrets, etc.), **nunca** no Git.

---

## Modelo `.env` local (sem segredos reais)

```env
PORT=3000
AWS_REGION=sa-east-1
AWS_PROFILE=bellx-dev

MONGO_URI=mongodb://127.0.0.1:27017/bellx
REDIS_HOST=127.0.0.1
REDIS_PORT=6381

BELLX_ENABLE_DB_API=1
BELLX_ADMIN_PASSWORD=<definir_localmente>
BELLX_ADMIN_SESSION_SECRET=<string_longa_aleatoria>
```

Se usares access keys (VPS ou política da org), troca `AWS_PROFILE` por `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` e **não** mistures os dois no mesmo `.env`.
