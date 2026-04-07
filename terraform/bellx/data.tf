data "aws_caller_identity" "current" {}

data "aws_subnets" "in_vpc" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
}

data "aws_subnet" "each" {
  for_each = toset(data.aws_subnets.in_vpc.ids)
  id       = each.value
}

locals {
  private_subnet_ids = sort([for id, s in data.aws_subnet.each : id if !coalesce(s.map_public_ip_on_launch, false)])
  public_subnet_ids  = sort([for id, s in data.aws_subnet.each : id if coalesce(s.map_public_ip_on_launch, false)])

  policy_dir = coalesce(var.policy_dir, "${path.module}/../../scripts/policies")

  dynamo_json_path = coalesce(var.dynamodb_tables_json, "${path.module}/../../scripts/dynamodb-tables.json")
  dynamo_spec      = jsondecode(file(local.dynamo_json_path))
  dynamo_tables    = { for t in local.dynamo_spec.tables : t.TableName => t }
}

data "aws_security_group" "redis" {
  vpc_id = var.vpc_id
  filter {
    name   = "group-name"
    values = ["bellx-redis-sg"]
  }
}

data "aws_security_group" "alb" {
  vpc_id = var.vpc_id
  filter {
    name   = "group-name"
    values = ["bellx-alb-sg"]
  }
}

data "aws_security_group" "backend" {
  vpc_id = var.vpc_id
  filter {
    name   = "group-name"
    values = ["bellx-backend-sg"]
  }
}
