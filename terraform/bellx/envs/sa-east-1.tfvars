# BellX — sa-east-1 (valores alinhados a scripts/bellx-sa-east-1-outputs.json).
# Uso:
#   cd terraform/bellx
#   terraform init
#   terraform plan  -var-file=envs/sa-east-1.tfvars
#   terraform apply -var-file=envs/sa-east-1.tfvars
#
# Se parte da infra ja existir (script PowerShell), importe antes do primeiro apply — ver README.md nesta pasta.

aws_region      = "sa-east-1"
vpc_id          = "vpc-04f95b0a5d7518417"
bucket_suffix   = "-sae1"
manage_iam_roles = false

# Descomente apos publicar imagem na ECR (mesma conta/regiao):
# backend_image = "790762402245.dkr.ecr.sa-east-1.amazonaws.com/bellx-backend:latest"

# Certificado ACM na mesma regiao (opcional):
# acm_certificate_arn = "arn:aws:acm:sa-east-1:790762402245:certificate/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

default_tags = {
  Project     = "BellX"
  ManagedBy   = "terraform"
  Environment = "sa-east-1"
}
