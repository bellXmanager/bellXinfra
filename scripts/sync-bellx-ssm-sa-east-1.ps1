#Requires -Version 5.1
<#
.SYNOPSIS
  Grava em SSM (/bellx/redis/* e /bellx/dynamodb/table/*) a partir do ElastiCache Serverless
  existente e de dynamodb-tables.json. Idempotente; útil após Leapp login ou quando Terraform
  ainda não geriu estes parâmetros.

.EXAMPLE
  .\sync-bellx-ssm-sa-east-1.ps1
  .\sync-bellx-ssm-sa-east-1.ps1 -Region sa-east-1 -RedisCacheName bellx-redis-cache
#>
[CmdletBinding()]
param(
    [string]$Region = "sa-east-1",
    [string]$RedisCacheName = "bellx-redis-cache",
    [string]$DynamoSpecPath = ""
)

$ErrorActionPreference = "Stop"
if (-not $DynamoSpecPath) {
    $DynamoSpecPath = Join-Path $PSScriptRoot "dynamodb-tables.json"
}
if (-not (Test-Path -LiteralPath $DynamoSpecPath)) {
    throw "Nao encontrado: $DynamoSpecPath"
}

function Invoke-AwsJson {
    param([string[]]$AwsCliArgs)
    $raw = & aws @AwsCliArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (@($raw) | Out-String).Trim()
    }
    return $raw | ConvertFrom-Json
}

Write-Host "Regiao: $Region" -ForegroundColor Cyan

$caches = Invoke-AwsJson -AwsCliArgs @("elasticache", "describe-serverless-caches", "--region", $Region, "--output", "json")
$cache = @($caches.ServerlessCaches) | Where-Object { $_.ServerlessCacheName -eq $RedisCacheName } | Select-Object -First 1
if (-not $cache) {
    throw "Serverless cache '$RedisCacheName' nao encontrado em $Region."
}
$addr = $cache.Endpoint.Address
if ([string]::IsNullOrWhiteSpace($addr)) {
    throw "Endpoint Address vazio para $RedisCacheName."
}

& aws ssm put-parameter --name "/bellx/redis/endpoint" --value $addr --type String --overwrite --region $Region | Out-Null
& aws ssm put-parameter --name "/bellx/redis/port" --value "6379" --type String --overwrite --region $Region | Out-Null
& aws ssm put-parameter --name "/bellx/redis/tls-port" --value "6380" --type String --overwrite --region $Region | Out-Null
Write-Host "SSM Redis OK (endpoint=$addr)" -ForegroundColor Green

$spec = Get-Content -LiteralPath $DynamoSpecPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($t in $spec.tables) {
    $tn = [string]$t.TableName
    $name = "/bellx/dynamodb/table/$tn"
    & aws ssm put-parameter --name $name --value $tn --type String --overwrite --region $Region | Out-Null
    Write-Host "SSM $name" -ForegroundColor DarkGray
}
Write-Host "SSM DynamoDB (tabelas do JSON): OK" -ForegroundColor Green
Write-Host "Concluido." -ForegroundColor Cyan
