# BellX — infra declarada (VPC/subnets/SGs existentes).
# VPC endpoints: bellXinfra/scripts/provision-bellx-sa-east-1.ps1 (Invoke-AwsIgnoreGatewayEndpointConflict no ramo VPC existente).
# Fora do Terraform por defeito para evitar conflitos com VPC ja provisionada.

check "network_layout" {
  assert {
    condition     = length(local.private_subnet_ids) >= 2 && length(local.public_subnet_ids) >= 2
    error_message = "Espere pelo menos 2 subnets privadas e 2 publicas na VPC (map-public-ip-on-launch)."
  }
}

resource "aws_iam_role" "ecs_execution" {
  count              = var.manage_iam_roles ? 1 : 0
  name               = "bellx-ecs-task-execution-role"
  assume_role_policy = file("${local.policy_dir}/ecs-task-trust.json")
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  count      = var.manage_iam_roles ? 1 : 0
  role       = aws_iam_role.ecs_execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "backend" {
  count              = var.manage_iam_roles ? 1 : 0
  name               = "bellx-backend-role"
  assume_role_policy = file("${local.policy_dir}/ecs-task-trust.json")
}

resource "aws_iam_role_policy" "backend_secrets" {
  count  = var.manage_iam_roles ? 1 : 0
  name   = "BellXReadSecrets"
  role   = aws_iam_role.backend[0].id
  policy = file("${local.policy_dir}/backend-secrets-read.json")
}

data "aws_iam_role" "ecs_execution" {
  count = var.manage_iam_roles ? 0 : (var.ecs_execution_role_arn == "" ? 1 : 0)
  name  = "bellx-ecs-task-execution-role"
}

data "aws_iam_role" "backend" {
  count = var.manage_iam_roles ? 0 : (var.backend_task_role_arn == "" ? 1 : 0)
  name  = "bellx-backend-role"
}

locals {
  ecs_execution_role_arn = var.manage_iam_roles ? aws_iam_role.ecs_execution[0].arn : (
    var.ecs_execution_role_arn != "" ? var.ecs_execution_role_arn : data.aws_iam_role.ecs_execution[0].arn
  )
  backend_task_role_arn = var.manage_iam_roles ? aws_iam_role.backend[0].arn : (
    var.backend_task_role_arn != "" ? var.backend_task_role_arn : data.aws_iam_role.backend[0].arn
  )
}

resource "aws_ecs_cluster" "bellx" {
  name = var.ecs_cluster_name
}

resource "aws_ecr_repository" "backend" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_s3_bucket" "assets" {
  for_each = toset(var.s3_bucket_bases)
  bucket   = "${each.key}${var.bucket_suffix}"
}

resource "aws_s3_bucket_public_access_block" "assets" {
  for_each = toset(var.s3_bucket_bases)
  bucket   = aws_s3_bucket.assets[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "bellx" {
  for_each = local.dynamo_tables

  name         = each.value.TableName
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = each.value.PartitionKey.Name

  attribute {
    name = each.value.PartitionKey.Name
    type = each.value.PartitionKey.Type
  }
}

resource "aws_elasticache_serverless_cache" "redis" {
  engine               = "valkey"
  name                 = var.redis_cache_name
  major_engine_version = "8"
  description          = "BellX Valkey sa-east-1"

  subnet_ids         = local.private_subnet_ids
  security_group_ids = [data.aws_security_group.redis.id]

  cache_usage_limits {
    data_storage {
      maximum = 10
      unit    = "GB"
    }
    ecpu_per_second {
      maximum = 5000
    }
  }

  # ModifyServerlessCache so permite um campo por pedido; import + drift de blocos
  # disparam varios deltas. Limites e versao ja estao no recurso importado.
  lifecycle {
    ignore_changes = [cache_usage_limits]
  }
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.task_family}"
  retention_in_days = 30
}

resource "aws_lb_target_group" "backend" {
  name        = var.target_group_name
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = var.health_check_path
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 3
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb" "bellx" {
  name               = var.alb_name
  internal           = false
  load_balancer_type = "application"
  security_groups    = [data.aws_security_group.alb.id]
  subnets            = local.public_subnet_ids

  tags = {
    Name = var.alb_name
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.bellx.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}

resource "aws_lb_listener" "https" {
  count             = var.acm_certificate_arn != "" ? 1 : 0
  load_balancer_arn = aws_lb.bellx.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}

resource "aws_ssm_parameter" "redis_endpoint" {
  name  = "/bellx/redis/endpoint"
  type  = "String"
  value = aws_elasticache_serverless_cache.redis.endpoint[0].address
}

resource "aws_ssm_parameter" "redis_port" {
  name  = "/bellx/redis/port"
  type  = "String"
  value = "6379"
}

resource "aws_ssm_parameter" "redis_tls_port" {
  name  = "/bellx/redis/tls-port"
  type  = "String"
  value = "6380"
}

resource "aws_ssm_parameter" "dynamodb_table" {
  for_each = local.dynamo_tables

  name  = "/bellx/dynamodb/table/${each.key}"
  type  = "String"
  value = each.key
}

resource "aws_ecs_task_definition" "backend" {
  count                    = var.backend_image != "" ? 1 : 0
  family                   = var.task_family
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = local.ecs_execution_role_arn
  task_role_arn            = local.backend_task_role_arn

  container_definitions = jsonencode([
    {
      name      = var.task_family
      image     = var.backend_image
      essential = true
      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]
      environment = concat(
        [
          { name = "PORT", value = tostring(var.container_port) },
          { name = "AWS_REGION", value = var.aws_region },
          { name = "REDIS_TLS", value = "true" }
        ],
        var.ecs_task_extra_environment
      )
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "backend" {
  count           = var.backend_image != "" ? 1 : 0
  name            = var.ecs_service_name
  cluster         = aws_ecs_cluster.bellx.id
  task_definition = aws_ecs_task_definition.backend[0].arn
  desired_count   = 1
  launch_type     = "FARGATE"

  platform_version = "LATEST"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = local.private_subnet_ids
    security_groups  = [data.aws_security_group.backend.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.backend.arn
    container_name   = var.task_family
    container_port   = var.container_port
  }

  health_check_grace_period_seconds = 90

  depends_on = [aws_lb_listener.http]
}
