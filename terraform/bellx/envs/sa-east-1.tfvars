# BellX — sa-east-1 (valores alinhados a scripts/bellx-sa-east-1-outputs.json).
# Uso:
#   cd terraform/bellx
#   terraform init
#   terraform plan  -var-file=envs/sa-east-1.tfvars
#   terraform apply -var-file=envs/sa-east-1.tfvars
#
# Se parte da infra ja existir (script PowerShell), importe antes do primeiro apply — ver README.md nesta pasta.

aws_region       = "sa-east-1"
vpc_id           = "vpc-04f95b0a5d7518417"
bucket_suffix    = "-sae1"
manage_iam_roles = false

# Evita iam:GetRole (Leapp/STS por vezes inconsistente neste endpoint). Conta BellX:
ecs_execution_role_arn = "arn:aws:iam::790762402245:role/bellx-ecs-task-execution-role"
backend_task_role_arn  = "arn:aws:iam::790762402245:role/bellx-backend-role"

backend_image = "790762402245.dkr.ecr.sa-east-1.amazonaws.com/bellx-backend:latest"

# Nome da tabela Companions (default Companions; igual a dynamodb-tables.json)
# companions_table_name = "Companions"

# Variaveis extra na task ECS (S3_BUCKET_* e BELLX_COMPANIONS_TABLE ja vao no main.tf)
# ecs_task_extra_environment = [
#   { name = "BELLX_ENABLE_DB_API", value = "0" },
# ]

# Certificado ACM na mesma regiao (opcional):
# acm_certificate_arn = "arn:aws:acm:sa-east-1:790762402245:certificate/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

default_tags = {
  Project     = "BellX"
  ManagedBy   = "terraform"
  Environment = "sa-east-1"
}
