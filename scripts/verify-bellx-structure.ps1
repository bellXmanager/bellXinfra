#Requires -Version 5.1
<#
.SYNOPSIS
  "Teste de estrutura": Terraform (fmt + validate + plan opcional) e contratos AWS em sa-east-1
  (DynamoDB + SSM /bellx/*). Requer AWS CLI com sessão válida (ex.: Leapp); IAM read pode falhar
  com token expirado — renovar sessão e repetir.

.PARAMETER SkipTerraformPlan
  Não executa terraform plan (útil se iam:GetRole falhar sem afetar o resto).

.EXAMPLE
  .\verify-bellx-structure.ps1
  .\verify-bellx-structure.ps1 -SkipTerraformPlan
#>
[CmdletBinding()]
param(
    [string]$Region = "sa-east-1",
    [string]$RedisCacheName = "bellx-redis-cache",
    [switch]$SkipTerraformPlan
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$tfDir = Join-Path $root "terraform\bellx"
$jsonPath = Join-Path $PSScriptRoot "dynamodb-tables.json"

function Fail($msg) {
    Write-Host $msg -ForegroundColor Red
    exit 1
}

Write-Host "==> Conta AWS" -ForegroundColor Cyan
try {
    $ident = aws sts get-caller-identity --output json | ConvertFrom-Json
    Write-Host ("  Account: " + $ident.Account + " ARN: " + $ident.Arn)
} catch {
    Fail "sts get-caller-identity falhou. Autentica no Leapp e exporta credenciais."
}

Write-Host "==> Terraform fmt -check" -ForegroundColor Cyan
Push-Location $tfDir
try {
    terraform fmt -check -recursive
    if ($LASTEXITCODE -ne 0) {
        Fail "Execute: cd `"$tfDir`" ; terraform fmt -recursive"
    }
} finally {
    Pop-Location
}

Write-Host "==> Terraform validate" -ForegroundColor Cyan
Push-Location $tfDir
try {
    terraform init -input=false -upgrade
    if ($LASTEXITCODE -ne 0) { Fail "terraform init falhou." }
    terraform validate
    if ($LASTEXITCODE -ne 0) { Fail "terraform validate falhou." }
} finally {
    Pop-Location
}

if (-not $SkipTerraformPlan) {
    Write-Host "==> Terraform plan (sa-east-1.tfvars + ARNs IAM, sem GetRole)" -ForegroundColor Cyan
    Push-Location $tfDir
    try {
        terraform plan -input=false -no-color "-var-file=envs/sa-east-1.tfvars"
        $pc = $LASTEXITCODE
        if ($pc -ne 0) {
            Write-Host "plan falhou (exit $pc). Renovar sessao Leapp ou: -SkipTerraformPlan" -ForegroundColor Yellow
            exit $pc
        }
    } finally {
        Pop-Location
    }
}

Write-Host "==> DynamoDB: tabelas do catálogo activas ($Region)" -ForegroundColor Cyan
$spec = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($t in $spec.tables) {
    $tn = $t.TableName
    $d = aws dynamodb describe-table --table-name $tn --region $Region --output json | ConvertFrom-Json
    $st = $d.Table.TableStatus
    if ($st -ne "ACTIVE") {
        Fail "Tabela $tn status=$st (esperado ACTIVE)"
    }
    Write-Host "  OK $tn"
}

Write-Host "==> SSM: /bellx/redis e /bellx/dynamodb/table/*" -ForegroundColor Cyan
$required = @(
    "/bellx/redis/endpoint",
    "/bellx/redis/port",
    "/bellx/redis/tls-port"
)
foreach ($p in $required) {
    aws ssm get-parameter --name $p --region $Region --output json | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "Falta ou sem acesso: $p. Correr sync-bellx-ssm-sa-east-1.ps1" }
    Write-Host "  OK $p"
}
foreach ($t in $spec.tables) {
    $tn = $t.TableName
    $p = "/bellx/dynamodb/table/$tn"
    aws ssm get-parameter --name $p --region $Region --output json | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "Falta: $p. Correr sync-bellx-ssm-sa-east-1.ps1" }
}

Write-Host "==> ElastiCache Serverless: $RedisCacheName" -ForegroundColor Cyan
$caches = aws elasticache describe-serverless-caches --region $Region --output json | ConvertFrom-Json
$cache = @($caches.ServerlessCaches) | Where-Object { $_.ServerlessCacheName -eq $RedisCacheName } | Select-Object -First 1
if (-not $cache) { Fail "Cache $RedisCacheName nao encontrado em $Region." }
if ($cache.Status -ne "available") { Fail "Cache status=$($cache.Status)" }
Write-Host "  OK $($cache.Endpoint.Address)" -ForegroundColor Green

Write-Host "`nEstrutura OK (SP $Region)." -ForegroundColor Green
