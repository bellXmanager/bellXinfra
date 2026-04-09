#Requires -Version 5.1
<#
.SYNOPSIS
  Cria (idempotente) todas as tabelas definidas em dynamodb-tables.json na região indicada.
  Região por defeito: sa-east-1 (oficial). Outra região só para cenários pontuais de migração.

.EXAMPLE
  .\create-dynamodb-tables-from-json.ps1 -Region sa-east-1
#>
[CmdletBinding()]
param(
    [string]$Region = "sa-east-1",
    [string]$SpecPath = ""
)

$ErrorActionPreference = "Stop"
if (-not $SpecPath) {
    $SpecPath = Join-Path $PSScriptRoot "dynamodb-tables.json"
}
if (-not (Test-Path -LiteralPath $SpecPath)) {
    throw "Spec nao encontrado: $SpecPath"
}

function Test-DynamoTableExists {
    param([string]$TableName)
    $old = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $null = & aws dynamodb describe-table --table-name $TableName --region $Region 2>&1
    $ok = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $old
    return $ok
}

function Invoke-Aws {
    param([string[]]$AwsCliArgs)
    $out = & aws @AwsCliArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (@($out) | Out-String).Trim()
    }
    return $out
}

Write-Host "Regiao: $Region" -ForegroundColor Cyan
$spec = Get-Content -LiteralPath $SpecPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($t in $spec.tables) {
    $tn = $t.TableName
    $pk = $t.PartitionKey
    if (Test-DynamoTableExists $tn) {
        Write-Host "Ja existe: $tn"
        continue
    }
    Invoke-Aws @(
        "dynamodb", "create-table",
        "--table-name", $tn,
        "--billing-mode", "PAY_PER_REQUEST",
        "--attribute-definitions", "AttributeName=$($pk.Name),AttributeType=$($pk.Type)",
        "--key-schema", "AttributeName=$($pk.Name),KeyType=HASH",
        "--region", $Region
    ) | Out-Null
    Write-Host "Criada: $tn" -ForegroundColor Green
}

Write-Host "Concluido." -ForegroundColor Cyan
