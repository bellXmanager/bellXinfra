# BellX — Infraestrutura (`bellXinfra`)

Repositório de **infraestrutura como código** e **scripts operacionais** para o **BellX** (Fifty 2.0) na AWS, região **`sa-east-1` (São Paulo)**.

## O que está aqui

| Pasta / ficheiro | Conteúdo |
|------------------|----------|
| **`terraform/bellx/`** | Stack principal: IAM (opcional), ECS Fargate, ECR, ALB, DynamoDB, S3, ElastiCache Serverless (Valkey), SSM, CloudWatch. Ver o README dedicado em baixo. |
| **`scripts/`** | PowerShell: deploy Terraform + ECS, sync SSM, correção de trust IAM, provisionamento legado, `dynamodb-tables.json`, políticas JSON. |
| **`scripts/dynamodb-tables.json`** | Definição das tabelas DynamoDB (partilhada entre Terraform e documentação). |
| **`scripts/policies/`** | Trust e policies IAM (ex.: ECS task), S3 presign/CORS, guia [**IAM Identity Center / SSO**](scripts/policies/IAM-IDENTITY-CENTER.md). |
| **`deploy/`** | [**PM2 + Nginx**](deploy/README.md) exemplo para VPS (BellX API **3050**, Next interno **3002**). |

## Documentação detalhada

- **[Terraform BellX (`terraform/bellx/README.md`)](terraform/bellx/README.md)** — o que o módulo gere, pré-requisitos, `terraform plan`/`apply`, script de deploy, imports, ECS/IAM troubleshooting.
- **Contexto da aplicação e contratos SSM/Dynamo:** na raiz do monorepo, [`CONTEXT.md`](../CONTEXT.md) e [`PROJECT.md`](../PROJECT.md).

## Pré-requisitos típicos

- **Terraform** ≥ 1.5
- **AWS CLI** com credenciais válidas (ex.: **Leapp** / SSO)
- **PowerShell** (scripts em Windows; execução conforme política da máquina)

## Fluxo rápido (Terraform)

```powershell
cd terraform/bellx
terraform init
terraform plan  -var-file=envs/sa-east-1.tfvars
terraform apply -var-file=envs/sa-east-1.tfvars
```

Deploy com script (na pasta `scripts/`):

```powershell
.\deploy-bellx-terraform-ecs-sa-east-1.ps1 -PlanOnly
.\deploy-bellx-terraform-ecs-sa-east-1.ps1 -Apply -ForceEcsDeployment
```

Sincronizar parâmetros SSM com recursos reais:

```powershell
.\sync-bellx-ssm-sa-east-1.ps1
```

## Relação com o código

- **Backend:** [`bellXback`](../bellXback) — imagem Docker publicada no ECR referenciado pelo Terraform / pipeline.
- **Frontend:** [`bellXfront`](../bellXfront) — build do site; entrega e DNS podem depender de S3/CloudFront (ver `PROJECT.md`).

## Estado Terraform

Por defeito o state pode ser **local**. Para equipa ou CI, configura **backend remoto** (S3 + lock DynamoDB) — não incluído por defeito; ver nota no [README do Terraform](terraform/bellx/README.md).
