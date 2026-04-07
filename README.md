# bellXinfra

Repositório de **infraestrutura BellX** na AWS: Terraform, scripts de provisionamento (PowerShell), políticas IAM e especificação DynamoDB.

## Conteúdo

| Caminho | Descrição |
|---------|-----------|
| `terraform/bellx/` | Stack Terraform para `sa-east-1` (VPC existente). Ver `terraform/bellx/README.md`. |
| `scripts/provision-bellx-sa-east-1.ps1` | Provisionamento idempotente via AWS CLI. |
| `scripts/dynamodb-tables.json` | Tabelas DynamoDB iniciais (partilhado com Terraform). |
| `scripts/policies/` | JSON de trust e policies IAM para roles ECS. |
| `scripts/validate_policies.py` / `.mjs` | Validação opcional dos JSON de policy. |
| `scripts/bellx-sa-east-1-outputs.json` | Snapshot de IDs após último provisionamento (atualizar manualmente quando mudar). |

## Backend da aplicação

O código da API **não** está aqui: ver repositório/pasta **`bellXback`** no projeto da aplicação (Fifty 2.0).

## Documentação global

No monorepo Fifty 2.0: **`PROJECT.md`** (AWS, checklist) e **`CONTEXT.md`** (contexto da app).
