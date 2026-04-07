variable "aws_region" {
  type        = string
  description = "Regiao AWS (ex.: sa-east-1)."
  default     = "sa-east-1"
}

variable "vpc_id" {
  type        = string
  description = "ID da VPC BellX (ex.: vpc-xxx). Subnets e SGs sao descobertos automaticamente."
}

variable "bucket_suffix" {
  type        = string
  description = "Sufixo dos buckets S3 (ex.: -sae1). Pode ser vazio."
  default     = ""
}

variable "s3_bucket_bases" {
  type        = list(string)
  description = "Nomes base dos buckets antes do sufixo."
  default     = ["bellx-site-images", "bellx-site-static", "bellx-site-videos"]
}

variable "ecr_repository_name" {
  type    = string
  default = "bellx-backend"
}

variable "redis_cache_name" {
  type    = string
  default = "bellx-redis-cache"
}

variable "ecs_cluster_name" {
  type    = string
  default = "bellx-cluster"
}

variable "ecs_service_name" {
  type    = string
  default = "bellx-backend"
}

variable "task_family" {
  type    = string
  default = "bellx-backend"
}

variable "container_port" {
  type    = number
  default = 3000
}

variable "health_check_path" {
  type    = string
  default = "/health"
}

variable "alb_name" {
  type    = string
  default = "bellx-alb"
}

variable "target_group_name" {
  type    = string
  default = "bellx-backend-tg"
}

variable "acm_certificate_arn" {
  type        = string
  description = "Opcional. Certificado ACM na mesma regiao do ALB para listener 443."
  default     = ""
}

variable "dynamodb_tables_json" {
  type        = string
  description = "Caminho para dynamodb-tables.json (padrao: scripts do repositorio)."
  default     = null
}

variable "backend_image" {
  type        = string
  description = "Imagem ECR (ex.: ACCOUNT.dkr.ecr.sa-east-1.amazonaws.com/bellx-backend:tag). Vazio = nao cria task definition nem service."
  default     = ""
}

variable "manage_iam_roles" {
  type        = bool
  description = "Cria roles bellx-ecs-task-execution-role e bellx-backend-role. Se ja existirem, importe-as para o state antes do apply."
  default     = true
}

variable "policy_dir" {
  type        = string
  description = "Pasta com ecs-task-trust.json e backend-secrets-read.json."
  default     = null
}

variable "default_tags" {
  type = map(string)
  description = "Tags aplicadas a recursos que suportam default_tags do provider."
  default = {
    Project   = "BellX"
    ManagedBy = "terraform"
  }
}
