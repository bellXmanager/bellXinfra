#Requires -Version 5.1
<#
.SYNOPSIS
  Garante trust policy ecs-tasks.amazonaws.com nas roles usadas pelo Fargate.
  Corrige erro: "ECS was unable to assume the role ... bellx-backend-role".

.EXAMPLE
  cd bellXinfra/scripts
  .\fix-ecs-iam-trust-sa-east-1.ps1
  aws ecs update-service --cluster bellx-cluster --service bellx-backend --force-new-deployment --region sa-east-1
#>
$ErrorActionPreference = "Stop"

$policyDir = Join-Path $PSScriptRoot "policies"
$policyFile = Join-Path $policyDir "ecs-task-trust.json"
if (-not (Test-Path -LiteralPath $policyFile)) { throw "Nao encontrado: $policyFile" }

Write-Host "Pasta policy: $policyDir" -ForegroundColor Cyan
Write-Host "Aplicando trust Principal Service = ecs-tasks.amazonaws.com" -ForegroundColor Cyan

# No Windows o mais fiavel e correr a partir da pasta do JSON com caminho RELATIVO:
#   aws ... --policy-document file://ecs-task-trust.json
Push-Location $policyDir
try {
    $execRole = "bellx-ecs-task-execution-role"
    aws iam get-role --role-name $execRole --query "Role.RoleName" --output text *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n>>> Role de execucao em falta — a criar: $execRole" -ForegroundColor Yellow
        & aws iam create-role --role-name $execRole --assume-role-policy-document file://ecs-task-trust.json
        if ($LASTEXITCODE -ne 0) { throw "create-role falhou para $execRole" }
        & aws iam attach-role-policy --role-name $execRole --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
        if ($LASTEXITCODE -ne 0) { throw "attach-role-policy falhou para $execRole" }
        Write-Host "OK: $execRole criada com AmazonECSTaskExecutionRolePolicy" -ForegroundColor Green
    }

    foreach ($role in @("bellx-backend-role", $execRole)) {
        Write-Host "`n>>> update-assume-role-policy: $role" -ForegroundColor Yellow
        & aws iam update-assume-role-policy --role-name $role --policy-document file://ecs-task-trust.json
        if ($LASTEXITCODE -ne 0) {
            throw "Falhou update para $role. Precisas de iam:UpdateAssumeRolePolicy nesta role."
        }
        $doc = aws iam get-role --role-name $role --query "Role.AssumeRolePolicyDocument" --output json
        if ($LASTEXITCODE -ne 0) { throw "get-role falhou para $role" }
        Write-Host "Trust actual (Principal):" -ForegroundColor DarkGray
        Write-Host $doc
    }
} finally {
    Pop-Location
}

Write-Host "`nOK — trust aplicado. Forcar novo deploy:" -ForegroundColor Green
Write-Host "aws ecs update-service --cluster bellx-cluster --service bellx-backend --force-new-deployment --region sa-east-1"
