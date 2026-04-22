# BellX — Terraform (`sa-east-1`)

Visão geral do repositório `bellXinfra` (scripts, `dynamodb-tables.json`): **[`../../README.md`](../../README.md)**.

Infra declarativa para o núcleo BellX na AWS, assumindo **VPC, subnets e security groups já existentes** (mesmo desenho do `bellXinfra/scripts/provision-bellx-sa-east-1.ps1`). A partir da raiz do monorepo Fifty 2.0, esta pasta é `bellXinfra/terraform/bellx`.

## O que o Terraform gere

- IAM (opcional): `bellx-ecs-task-execution-role`, `bellx-backend-role` + policy de leitura de secrets + **`BellXS3PresignUpload`** (`scripts/policies/bellx-backend-s3-presign.json`) para presign S3
- ECS cluster, repositório ECR, buckets S3 + bloqueio de acesso público
- Tabelas DynamoDB (definição em `bellXinfra/scripts/dynamodb-tables.json`, caminho relativo ao Terraform: `../../scripts/`)
- ElastiCache Serverless (Valkey), log group CloudWatch, ALB + target group + listeners
- Parâmetros SSM `/bellx/redis/*` e `/bellx/dynamodb/table/*`
- Task definition + serviço Fargate **se** `backend_image` estiver definido (env na task: `PORT`, `AWS_REGION`, `REDIS_TLS`, **`S3_BUCKET_IMAGES`**, **`S3_BUCKET_VIDEOS`** — nomes dos buckets criados —, **`BELLX_COMPANIONS_TABLE`**, + `ecs_task_extra_environment`)

## O que fica de fora (por agora)

- **VPC endpoints** (gateway S3/Dynamo + interface SSM/ECR/…): continue a usar o script PowerShell uma vez por VPC ou importe endpoints para o state.
- **CloudFront**, **ACM via DNS**, **Secrets Manager** (segredos da app): configurar à parte.

## Pré-requisitos

- Terraform ≥ 1.5, AWS CLI configurado (ex.: Leapp). Com `manage_iam_roles = false`, preenche **`ecs_execution_role_arn`** e **`backend_task_role_arn`** no `tfvars` (ver `envs/sa-east-1.tfvars`) para evitar `iam:GetRole` quando o endpoint IAM responde `InvalidClientTokenId` com Leapp.
- Na VPC: SGs `bellx-endpoints-sg`, `bellx-redis-sg`, `bellx-alb-sg`, `bellx-backend-sg` (nomes de security group)
- Pelo menos **2 subnets públicas** e **2 privadas**

### SSM `/bellx/*` sem `apply` completo

Para alinhar parâmetros com o Valkey real e os nomes das tabelas DynamoDB:

```powershell
cd bellXinfra/scripts
.\sync-bellx-ssm-sa-east-1.ps1
```

### Verificação (“teste de estrutura”)

Na pasta `bellXback`: `npm run verify:structure` — testes, contratos AWS em `sa-east-1`, `terraform fmt`/`validate` e **`terraform plan`**.  
Atalho sem plan: `npm run verify:structure:aws`.

## ECS: "unable to assume the role bellx-backend-role"

`aws ecs update-service --force-new-deployment` **não** altera IAM — só redeploya. O erro de *assume role* só some depois de corrigir a **trust policy** das roles e de existir a **task execution role** referenciada na task definition.

As roles precisam de principal `ecs-tasks.amazonaws.com` (ver `scripts/policies/ecs-task-trust.json`). **Cuidado:** uma trust policy com `Condition` em `aws:SourceArn` **tem de usar a região onde o ECS corre** (ex.: `arn:aws:ecs:sa-east-1:CONTA:*`). Se estiver `us-east-1`/`us-east-2` errado, o assume falha mesmo com o serviço certo.

A role **`bellx-ecs-task-execution-role`** tem de existir (ECR pull, logs). O script `fix-ecs-iam-trust-sa-east-1.ps1` cria-a se faltar e alinha o trust das duas roles.

**Ordem:**

1. `cd bellXinfra/scripts` → `.\fix-ecs-iam-trust-sa-east-1.ps1`
2. `aws ecs update-service --cluster bellx-cluster --service bellx-backend --force-new-deployment --region sa-east-1`
3. Confirmar: `aws ecs describe-services --cluster bellx-cluster --services bellx-backend --region sa-east-1 --query "services[0].events[0].message"`

## Comandos

```powershell
cd bellXinfra/terraform/bellx
terraform init
terraform plan  -var-file=envs/sa-east-1.tfvars
terraform apply -var-file=envs/sa-east-1.tfvars
```

### Script (plan / apply + novo deploy ECS)

Na pasta `bellXinfra/scripts` (credenciais AWS ativas, ex. Leapp):

```powershell
.\deploy-bellx-terraform-ecs-sa-east-1.ps1 -PlanOnly
.\deploy-bellx-terraform-ecs-sa-east-1.ps1 -Apply -ForceEcsDeployment
```

Depois do `apply` que altera a task definition, o ECS pode criar tasks com a nova revisão; `-ForceEcsDeployment` garante rollout mesmo quando a imagem não mudou.

`envs/sa-east-1.tfvars` usa `manage_iam_roles = false` quando as roles já foram criadas pelo script (evita conflito). Para stack nova só Terraform, use `manage_iam_roles = true` nesse ficheiro ou noutro `-var-file`.

## Já existe recurso criado pelo script?

Não mistures **criar de novo** com **adotar**: importa para o state ou apaga no console e deixa o Terraform criar.

Exemplos (ajusta nomes de bucket se o sufixo for outro):

```text
terraform import aws_ecr_repository.backend bellx-backend
terraform import aws_ecs_cluster.bellx bellx-cluster
terraform import aws_elasticache_serverless_cache.redis bellx-redis-cache
terraform import "aws_s3_bucket.assets[\"bellx-site-images\"]" bellx-site-images-sae1
terraform import "aws_s3_bucket.assets[\"bellx-site-static\"]" bellx-site-static-sae1
terraform import "aws_s3_bucket.assets[\"bellx-site-videos\"]" bellx-site-videos-sae1
```

Para tabelas DynamoDB e parâmetros SSM, o comando é análogo (`terraform import` com o endereço do recurso e o nome/ID na AWS).

## Ficheiros

| Ficheiro | Função |
|----------|--------|
| `envs/sa-east-1.tfvars` | Valores para São Paulo (VPC BellX já referenciada) |
| `terraform.tfvars.example` | Modelo genérico se não usares `envs/` |
| `../../scripts/dynamodb-tables.json` | Esquema das tabelas (partilhado com o script) |
| `../../scripts/policies/*.json` | Trust e policy inline IAM |

## Estado remoto (equipa / CI)

Por defeito o state é local. Para partilhar, configura um backend S3 + DynamoDB lock num ficheiro `backend.tf` (não incluído aqui).
