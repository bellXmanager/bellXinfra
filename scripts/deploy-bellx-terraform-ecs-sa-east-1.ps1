#Requires -Version 5.1
<#
.SYNOPSIS
  terraform plan/apply em bellXinfra/terraform/bellx + opcional novo deploy ECS.

.DESCRIPTION
  Usa envs/sa-east-1.tfvars. Exige AWS CLI autenticado (ex.: Leapp) na conta BellX.

.PARAMETER PlanOnly
  So corre terraform plan (sem apply).

.PARAMETER Apply
  Corre terraform apply (pede confirmacao interactiva salvo -AutoApprove).

.PARAMETER AutoApprove
  terraform apply -auto-approve (CUIDADO em producao).

.PARAMETER ForceEcsDeployment
  Apos apply (ou sempre se usar com SkipTerraform), corre update-service --force-new-deployment.

.PARAMETER SkipTerraform
  Nao corre terraform; so ForceEcsDeployment se combinado.

.EXAMPLE
  cd bellXinfra/scripts
  .\deploy-bellx-terraform-ecs-sa-east-1.ps1 -PlanOnly

.EXAMPLE
  .\deploy-bellx-terraform-ecs-sa-east-1.ps1 -Apply -ForceEcsDeployment
#>
param(
    [switch] $PlanOnly,
    [switch] $Apply,
    [switch] $AutoApprove,
    [switch] $ForceEcsDeployment,
    [switch] $SkipTerraform
)

$ErrorActionPreference = "Stop"
$tfDir = Join-Path $PSScriptRoot "..\terraform\bellx" | Resolve-Path

Write-Host "Terraform: $tfDir" -ForegroundColor Cyan
Set-Location $tfDir.Path

if (-not $SkipTerraform) {
    & terraform init -input=false
    if ($LASTEXITCODE -ne 0) { throw "terraform init falhou" }

    $varFile = Join-Path $tfDir.Path "envs\sa-east-1.tfvars"
    if (-not (Test-Path -LiteralPath $varFile)) { throw "Ficheiro em falta: $varFile" }

    if ($PlanOnly) {
        & terraform plan -input=false --var-file="$varFile"
        if ($LASTEXITCODE -ne 0) { throw "terraform plan falhou" }
        Write-Host "`nPlan concluido. Para aplicar: -Apply" -ForegroundColor Green
    }
    elseif ($Apply) {
        if ($AutoApprove) {
            & terraform apply -input=false -auto-approve --var-file="$varFile"
        }
        else {
            & terraform apply -input=false --var-file="$varFile"
        }
        if ($LASTEXITCODE -ne 0) { throw "terraform apply falhou" }
        Write-Host "`nApply concluido." -ForegroundColor Green
    }
    else {
        Write-Host "Nada a fazer: use -PlanOnly ou -Apply (ou -SkipTerraform com -ForceEcsDeployment)." -ForegroundColor Yellow
    }
}

$region = "sa-east-1"
$cluster = "bellx-cluster"
$service = "bellx-backend"

if ($ForceEcsDeployment) {
    Write-Host "`nForcar novo deploy ECS: $cluster / $service ($region)..." -ForegroundColor Cyan
    & aws ecs update-service --cluster $cluster --service $service --force-new-deployment --region $region
    if ($LASTEXITCODE -ne 0) { throw "update-service falhou" }
    Write-Host "Pedido de deploy enviado. Ver: aws ecs describe-services --cluster $cluster --services $service --region $region" -ForegroundColor Green
}
