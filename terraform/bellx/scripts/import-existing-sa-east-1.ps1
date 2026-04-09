#Requires -Version 5.1
# Importa recursos BellX ja existentes em sa-east-1 para o state local.
# Uso (a partir de bellXinfra/terraform/bellx):
#   powershell -ExecutionPolicy Bypass -File scripts/import-existing-sa-east-1.ps1
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $PSScriptRoot
Set-Location $here

function Invoke-TerraformImport {
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][string]$Id
    )
    Write-Host "terraform import $Address $Id" -ForegroundColor DarkGray
    & terraform import "-var-file=envs/sa-east-1.tfvars" $Address $Id
    if ($LASTEXITCODE -ne 0) { throw "import failed: $Address" }
}

Invoke-TerraformImport "aws_ecs_cluster.bellx" "bellx-cluster"
Invoke-TerraformImport "aws_elasticache_serverless_cache.redis" "bellx-redis-cache"

foreach ($base in @("bellx-site-images", "bellx-site-static", "bellx-site-videos")) {
    $bucket = "${base}-sae1"
    Invoke-TerraformImport "aws_s3_bucket.assets[`"$base`"]" $bucket
}

foreach ($base in @("bellx-site-images", "bellx-site-static", "bellx-site-videos")) {
    $bucket = "${base}-sae1"
    Invoke-TerraformImport "aws_s3_bucket_public_access_block.assets[`"$base`"]" $bucket
}

$tables = @(
    "Advertisers", "Media", "Profiles", "Transactions",
    "bellx-users", "bellx-sessions", "bellx-events", "bellx-config"
)
foreach ($t in $tables) {
    Invoke-TerraformImport "aws_dynamodb_table.bellx[`"$t`"]" $t
}

Invoke-TerraformImport "aws_ssm_parameter.redis_endpoint" "/bellx/redis/endpoint"
Invoke-TerraformImport "aws_ssm_parameter.redis_port" "/bellx/redis/port"
Invoke-TerraformImport "aws_ssm_parameter.redis_tls_port" "/bellx/redis/tls-port"

foreach ($t in $tables) {
    Invoke-TerraformImport "aws_ssm_parameter.dynamodb_table[`"$t`"]" "/bellx/dynamodb/table/$t"
}

Write-Host "`nImports OK. Proximo: terraform plan -var-file=envs/sa-east-1.tfvars" -ForegroundColor Green
