output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "vpc_id" {
  value = var.vpc_id
}

output "public_subnet_ids" {
  value = local.public_subnet_ids
}

output "private_subnet_ids" {
  value = local.private_subnet_ids
}

output "ecr_repository_url" {
  value = aws_ecr_repository.backend.repository_url
}

output "redis_endpoint" {
  value = aws_elasticache_serverless_cache.redis.endpoint[0].address
}

output "alb_dns_name" {
  value = aws_lb.bellx.dns_name
}

output "alb_arn" {
  value = aws_lb.bellx.arn
}

output "target_group_arn" {
  value = aws_lb_target_group.backend.arn
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.bellx.name
}

output "dynamodb_table_names" {
  value = keys(local.dynamo_tables)
}

output "s3_bucket_ids" {
  value = [for b in aws_s3_bucket.assets : b.id]
}
