# BellX — Terraform (`sa-east-1`)

Infra declarativa para o núcleo BellX na AWS, assumindo **VPC, subnets e security groups já existentes** (mesmo desenho do `bellXinfra/scripts/provision-bellx-sa-east-1.ps1`). A partir da raiz do monorepo Fifty 2.0, esta pasta é `bellXinfra/terraform/bellx`.

## O que o Terraform gere

- IAM (opcional): `bellx-ecs-task-execution-role`, `bellx-backend-role` + policy de leitura de secrets
- ECS cluster, repositório ECR, buckets S3 + bloqueio de acesso público
- Tabelas DynamoDB (definição em `bellXinfra/scripts/dynamodb-tables.json`, caminho relativo ao Terraform: `../../scripts/`)
- ElastiCache Serverless (Valkey), log group CloudWatch, ALB + target group + listeners
- Parâmetros SSM `/bellx/redis/*` e `/bellx/dynamodb/table/*`
- Task definition + serviço Fargate **se** `backend_image` estiver definido

## O que fica de fora (por agora)

- **VPC endpoints** (gateway S3/Dynamo + interface SSM/ECR/…): continue a usar o script PowerShell uma vez por VPC ou importe endpoints para o state.
- **CloudFront**, **ACM via DNS**, **Secrets Manager** (segredos da app): configurar à parte.

## Pré-requisitos

- Terraform ≥ 1.5, AWS CLI configurado (ex.: Leapp)
- Na VPC: SGs `bellx-endpoints-sg`, `bellx-redis-sg`, `bellx-alb-sg`, `bellx-backend-sg` (nomes de security group)
- Pelo menos **2 subnets públicas** e **2 privadas**

## Comandos

```powershell
cd bellXinfra/terraform/bellx
terraform init
terraform plan  -var-file=envs/sa-east-1.tfvars
terraform apply -var-file=envs/sa-east-1.tfvars
```

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
