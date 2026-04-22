#Requires -Version 5.1
<#
.SYNOPSIS
  Cria (se nao existir) utilizador IAM para o backend BellX em producao na VPS,
  anexa politica S3 presign (bellx-backend-s3-presign.json) e gera UM par de access keys.

  Corre com AWS CLI autenticado (ex.: Leapp com perfil admin na conta certa).
  O SecretAccessKey so aparece UMA vez na saida — guarda no Hostinger/env seguro.

.PARAMETER UserName
  Nome do utilizador IAM (default: bellx-vps-production)

.EXAMPLE
  cd bellXinfra\scripts
  .\create-bellx-production-service-user.ps1
#>
param(
  [string] $UserName = "bellx-vps-production"
)

$ErrorActionPreference = "Stop"
$PolicyPath = Join-Path $PSScriptRoot "policies\bellx-backend-s3-presign.json"
if (-not (Test-Path $PolicyPath)) {
  Write-Error "Ficheiro de politica nao encontrado: $PolicyPath"
}

Write-Host "=== Identidade AWS atual ===" -ForegroundColor Cyan
aws sts get-caller-identity | ConvertFrom-Json | Format-List

Write-Host "=== Utilizador IAM: $UserName ===" -ForegroundColor Cyan
$null = aws iam get-user --user-name $UserName 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host "A criar utilizador..."
  aws iam create-user --user-name $UserName | Out-Null
  Write-Host "Utilizador criado."
} else {
  Write-Host "Utilizador ja existe."
}

Write-Host "A anexar politica inline BellXS3PresignUpload..."
$policyUri = "file://" + ($PolicyPath -replace "\\", "/")
aws iam put-user-policy `
  --user-name $UserName `
  --policy-name BellXS3PresignUpload `
  --policy-document $policyUri

$keys = aws iam list-access-keys --user-name $UserName | ConvertFrom-Json
$n = $keys.AccessKeyMetadata.Count
if ($n -ge 2) {
  Write-Error "O utilizador ja tem 2 access keys (limite IAM). Apaga uma na consola IAM e volta a correr o script."
}

Write-Host ""
Write-Host "=== NOVAS CREDENCIAIS (copiar agora para env seguro; nao commitar) ===" -ForegroundColor Yellow
$out = aws iam create-access-key --user-name $UserName | ConvertFrom-Json
$ak = $out.AccessKey.AccessKeyId
$sk = $out.AccessKey.SecretAccessKey
Write-Host "AWS_ACCESS_KEY_ID=$ak"
Write-Host "AWS_SECRET_ACCESS_KEY=$sk"
Write-Host ""
Write-Host "Coloca na VPS (systemd/Docker) e apaga do historico do terminal se precisares." -ForegroundColor DarkGray
