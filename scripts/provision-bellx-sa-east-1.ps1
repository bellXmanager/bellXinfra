#Requires -Version 5.1
# BellX provision sa-east-1 (idempotente): rede, Valkey, DynamoDB, ECR, ALB, ECS (opcional imagem), SSM.
# DynamoDB: edite dynamodb-tables.json (esta pasta, bellXinfra/scripts).
# Pre-check: python validate_policies.py (a partir desta pasta).
[CmdletBinding()]
param(
    [string]$Region = "sa-east-1",
    [string]$VpcCidr = "10.0.0.0/16",
    [string[]]$Azs = @("sa-east-1a", "sa-east-1b"),
    [string]$BucketSuffix = "",
    [string]$EcrRepositoryName = "bellx-backend",
    [int]$ContainerPort = 3000,
    [string]$BackendImageUri = "",
    [string]$AcmCertificateArn = "",
    [string]$HealthCheckPath = "/health",
    [string]$DynamoDbSpecPath = "",
    [string]$EcsServiceName = "bellx-backend",
    [string]$TaskDefinitionFamily = "bellx-backend",
    [string]$AlbName = "bellx-alb",
    [string]$TargetGroupName = "bellx-backend-tg"
)

$ErrorActionPreference = "Stop"
if (-not $DynamoDbSpecPath) {
    $DynamoDbSpecPath = Join-Path $PSScriptRoot "dynamodb-tables.json"
}

function Invoke-Aws {
    param([string[]]$AwsCliArgs)
    # SilentlyContinue drops native stderr on Windows so $out is null and errors are invisible.
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & aws @AwsCliArgs 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            $flat = (@($out) | Out-String).Trim()
            if (-not $flat) { $flat = "(aws exit $code; stderr not captured; run the same aws command in a shell)" }
            throw "aws $($AwsCliArgs -join ' ') failed: $flat"
        }
        return $out
    } finally {
        $ErrorActionPreference = $old
    }
}

function Invoke-AwsQuiet {
    param([string[]]$AwsCliArgs)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & aws @AwsCliArgs 2>&1
        $text = ($raw | Where-Object { $_ -is [string] } | Select-Object -Last 1)
        if (-not $text) { $text = (@($raw) | Out-String).Trim() }
        return $text
    } finally {
        $ErrorActionPreference = $old
    }
}

function Invoke-AwsIgnoreDuplicate {
    param([string[]]$AwsCliArgs)
    try {
        # Variable splat (@$arr) binds only the first token to [string[]]; pass the array by value.
        Invoke-Aws $AwsCliArgs
    } catch {
        $m = ($_ | Out-String) + $_.Exception.Message
        if ($m -match 'InvalidPermission\.Duplicate|already exists|specified rule') { return }
        throw
    }
}

function Get-PolicyFileUri {
    param([Parameter(Mandatory)][string]$RelativePath)
    $full = Join-Path $PSScriptRoot $RelativePath
    if (-not (Test-Path -LiteralPath $full)) {
        throw "Arquivo de policy nao encontrado: $full"
    }
    $resolved = (Resolve-Path -LiteralPath $full).Path
    return 'file://' + ($resolved -replace '\\', '/')
}

function Get-ExistingBellxVpcId {
    $t = Invoke-AwsQuiet @('ec2', 'describe-vpcs', '--region', $Region, '--filters', 'Name=tag:Name,Values=bellx-vpc', '--query', 'Vpcs[0].VpcId', '--output', 'text')
    if ([string]::IsNullOrWhiteSpace($t) -or $t -eq 'None') { return $null }
    return $t.Trim()
}

function Get-SgIdInVpc {
    param([string]$VpcId, [string]$GroupName)
    $j = Invoke-Aws @('ec2', 'describe-security-groups', '--region', $Region, '--filters', "Name=vpc-id,Values=$VpcId", "Name=group-name,Values=$GroupName", '--output', 'json') | ConvertFrom-Json
    if ($j.SecurityGroups.Count -ge 1) { return $j.SecurityGroups[0].GroupId }
    return $null
}

function Test-S3BucketExists {
    param([string]$BucketName)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $null = & aws s3api head-bucket --bucket $BucketName --region $Region 2>&1
    $ok = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $old
    return $ok
}

function Test-VpcEndpointGatewayExists {
    param([string]$VpcId, [string]$ServiceName)
    $j = Invoke-Aws @(
        'ec2', 'describe-vpc-endpoints', '--region', $Region,
        '--filters',
        "Name=vpc-id,Values=$VpcId",
        "Name=service-name,Values=$ServiceName",
        'Name=vpc-endpoint-type,Values=Gateway',
        '--output', 'json'
    ) | ConvertFrom-Json
    $active = @($j.VpcEndpoints) | Where-Object { $_.State -notin @('deleted', 'rejected', 'failed') }
    return ($active.Count -gt 0)
}

function Invoke-AwsIgnoreGatewayEndpointConflict {
    param([string[]]$AwsCliArgs)
    try {
        Invoke-Aws $AwsCliArgs
    } catch {
        $m = ($_ | Out-String) + $_.Exception.Message
        if ($m -match 'RouteAlreadyExists|DuplicateVpcEndpoint|already exists') { return }
        throw
    }
}

function Test-VpcEndpointInterfaceExists {
    param([string]$VpcId, [string]$ServiceName)
    $j = Invoke-Aws @('ec2', 'describe-vpc-endpoints', '--region', $Region, '--filters', "Name=vpc-id,Values=$VpcId", "Name=service-name,Values=$ServiceName", '--output', 'json') | ConvertFrom-Json
    $active = @($j.VpcEndpoints) | Where-Object { $_.VpcEndpointType -eq 'Interface' -and $_.State -ne 'deleted' }
    return ($active.Count -gt 0)
}

function Test-DynamoTableExists {
    param([string]$TableName)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $null = & aws dynamodb describe-table --table-name $TableName --region $Region 2>&1
    $ok = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $old
    return $ok
}

# --- IAM ---
Write-Host "==> Conta e IAM" -ForegroundColor Cyan
$ident = Invoke-Aws @("sts", "get-caller-identity", "--output", "json") | ConvertFrom-Json
$AccountId = $ident.Account
Write-Host "Account: $AccountId"

try {
    Invoke-Aws @("iam", "get-role", "--role-name", "bellx-backend-role", "--output", "json") | Out-Null
    Write-Host "IAM OK: bellx-backend-role existe."
} catch {
    Write-Host 'IAM: criando roles (scripts/policies/)...' -ForegroundColor Yellow
    $trustUri = Get-PolicyFileUri 'policies\ecs-task-trust.json'
    $secretsUri = Get-PolicyFileUri 'policies\backend-secrets-read.json'
    try { Invoke-Aws @('iam', 'create-role', '--role-name', 'bellx-ecs-task-execution-role', '--assume-role-policy-document', $trustUri) } catch { Write-Host '  (execution role ja existe)' }
    try { Invoke-Aws @('iam', 'attach-role-policy', '--role-name', 'bellx-ecs-task-execution-role', '--policy-arn', 'arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy') } catch { }
    try { Invoke-Aws @('iam', 'create-role', '--role-name', 'bellx-backend-role', '--assume-role-policy-document', $trustUri) } catch { Write-Host '  (backend role ja existe)' }
    $managed = @(
        'arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess',
        'arn:aws:iam::aws:policy/AmazonS3FullAccess',
        'arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly',
        'arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess',
        'arn:aws:iam::aws:policy/CloudWatchLogsFullAccess',
        'arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess'
    )
    foreach ($p in $managed) {
        try { Invoke-Aws @('iam', 'attach-role-policy', '--role-name', 'bellx-backend-role', '--policy-arn', $p) } catch { }
    }
    try { Invoke-Aws @('iam', 'put-role-policy', '--role-name', 'bellx-backend-role', '--policy-name', 'BellXReadSecrets', '--policy-document', $secretsUri) } catch { }
}

$execRoleArn = "arn:aws:iam::${AccountId}:role/bellx-ecs-task-execution-role"
$taskRoleArn = "arn:aws:iam::${AccountId}:role/bellx-backend-role"

$vpcId = Get-ExistingBellxVpcId
$igwId = $null
$publicSubnets = @()
$privateSubnets = @()
$pubRt = $null
$privRt = $null
$sgEndpoints = $null
$sgRedis = $null
$sgAlb = $null
$sgBackend = $null

if (-not $vpcId) {
    Write-Host "`n==> VPC e subnets (nova VPC)" -ForegroundColor Cyan
    $vpcId = (Invoke-Aws @("ec2", "create-vpc", "--cidr-block", $VpcCidr, "--region", $Region, "--tag-specifications", 'ResourceType=vpc,Tags=[{Key=Name,Value=bellx-vpc}]', "--output", "json") | ConvertFrom-Json).Vpc.VpcId
    Invoke-Aws @("ec2", "modify-vpc-attribute", "--vpc-id", $vpcId, "--enable-dns-hostnames", "--region", $Region)
    Invoke-Aws @("ec2", "modify-vpc-attribute", "--vpc-id", $vpcId, "--enable-dns-support", "--region", $Region)
    Write-Host "VPC: $vpcId"

    $igwId = (Invoke-Aws @("ec2", "create-internet-gateway", "--region", $Region, "--tag-specifications", 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=bellx-igw}]', "--output", "json") | ConvertFrom-Json).InternetGateway.InternetGatewayId
    Invoke-Aws @("ec2", "attach-internet-gateway", "--internet-gateway-id", $igwId, "--vpc-id", $vpcId, "--region", $Region)

    $pubCidrs = @("10.0.0.0/20", "10.0.16.0/20")
    $privCidrs = @("10.0.128.0/20", "10.0.144.0/20")
    for ($i = 0; $i -lt 2; $i++) {
        $az = $Azs[$i]
        $tagPub = 'ResourceType=subnet,Tags=[{Key=Name,Value=bellx-subnet-public' + ($i + 1) + '-' + $az + '}]'
        $snPub = (Invoke-Aws @("ec2", "create-subnet", "--vpc-id", $vpcId, "--cidr-block", $pubCidrs[$i], "--availability-zone", $az, "--region", $Region, "--tag-specifications", $tagPub, "--output", "json") | ConvertFrom-Json).Subnet.SubnetId
        Invoke-Aws @("ec2", "modify-subnet-attribute", "--subnet-id", $snPub, "--map-public-ip-on-launch", "--region", $Region)
        $publicSubnets += $snPub
        $tagPriv = 'ResourceType=subnet,Tags=[{Key=Name,Value=bellx-subnet-private' + ($i + 1) + '-' + $az + '}]'
        $snPriv = (Invoke-Aws @("ec2", "create-subnet", "--vpc-id", $vpcId, "--cidr-block", $privCidrs[$i], "--availability-zone", $az, "--region", $Region, "--tag-specifications", $tagPriv, "--output", "json") | ConvertFrom-Json).Subnet.SubnetId
        $privateSubnets += $snPriv
    }

    $pubRt = (Invoke-Aws @("ec2", "create-route-table", "--vpc-id", $vpcId, "--region", $Region, "--tag-specifications", 'ResourceType=route-table,Tags=[{Key=Name,Value=bellx-rt-public}]', "--output", "json") | ConvertFrom-Json).RouteTable.RouteTableId
    Invoke-Aws @("ec2", "create-route", "--route-table-id", $pubRt, "--destination-cidr-block", "0.0.0.0/0", "--gateway-id", $igwId, "--region", $Region)
    foreach ($s in $publicSubnets) {
        Invoke-Aws @("ec2", "associate-route-table", "--subnet-id", $s, "--route-table-id", $pubRt, "--region", $Region)
    }
    $privRt = (Invoke-Aws @("ec2", "create-route-table", "--vpc-id", $vpcId, "--region", $Region, "--tag-specifications", 'ResourceType=route-table,Tags=[{Key=Name,Value=bellx-rt-private}]', "--output", "json") | ConvertFrom-Json).RouteTable.RouteTableId
    foreach ($s in $privateSubnets) {
        Invoke-Aws @("ec2", "associate-route-table", "--subnet-id", $s, "--route-table-id", $privRt, "--region", $Region)
    }

    Write-Host "`n==> Security groups (sem SQL/RDS)" -ForegroundColor Cyan
    $sgEndpoints = (Invoke-Aws @("ec2", "create-security-group", "--group-name", "bellx-endpoints-sg", "--description", "BellX VPC interface endpoints", "--vpc-id", $vpcId, "--region", $Region, "--output", "json") | ConvertFrom-Json).GroupId
    Invoke-Aws @("ec2", "create-tags", "--resources", $sgEndpoints, "--tags", "Key=Name,Value=bellx-endpoints-sg", "--region", $Region)
    $sgRedis = (Invoke-Aws @("ec2", "create-security-group", "--group-name", "bellx-redis-sg", "--description", "BellX Valkey", "--vpc-id", $vpcId, "--region", $Region, "--output", "json") | ConvertFrom-Json).GroupId
    Invoke-Aws @("ec2", "create-tags", "--resources", $sgRedis, "--tags", "Key=Name,Value=bellx-redis-sg", "--region", $Region)
    $sgAlb = (Invoke-Aws @("ec2", "create-security-group", "--group-name", "bellx-alb-sg", "--description", "BellX ALB", "--vpc-id", $vpcId, "--region", $Region, "--output", "json") | ConvertFrom-Json).GroupId
    Invoke-Aws @("ec2", "create-tags", "--resources", $sgAlb, "--tags", "Key=Name,Value=bellx-alb-sg", "--region", $Region)
    $sgBackend = (Invoke-Aws @("ec2", "create-security-group", "--group-name", "bellx-backend-sg", "--description", "BellX ECS tasks", "--vpc-id", $vpcId, "--region", $Region, "--output", "json") | ConvertFrom-Json).GroupId
    Invoke-Aws @("ec2", "create-tags", "--resources", $sgBackend, "--tags", "Key=Name,Value=bellx-backend-sg", "--region", $Region)

    Invoke-AwsIgnoreDuplicate @("ec2", "authorize-security-group-ingress", "--group-id", $sgEndpoints, "--protocol", "tcp", "--port", "443", "--cidr", $VpcCidr, "--region", $Region)
    Invoke-AwsIgnoreDuplicate @("ec2", "authorize-security-group-ingress", "--group-id", $sgAlb, "--protocol", "tcp", "--port", "80", "--cidr", "0.0.0.0/0", "--region", $Region)
    Invoke-AwsIgnoreDuplicate @("ec2", "authorize-security-group-ingress", "--group-id", $sgAlb, "--protocol", "tcp", "--port", "443", "--cidr", "0.0.0.0/0", "--region", $Region)
    Invoke-AwsIgnoreDuplicate @("ec2", "authorize-security-group-ingress", "--group-id", $sgBackend, "--protocol", "tcp", "--port", $ContainerPort, "--source-group", $sgAlb, "--region", $Region)
    Invoke-AwsIgnoreDuplicate @("ec2", "authorize-security-group-ingress", "--group-id", $sgRedis, "--protocol", "tcp", "--port", "6379", "--source-group", $sgBackend, "--region", $Region)
    Invoke-AwsIgnoreDuplicate @("ec2", "authorize-security-group-ingress", "--group-id", $sgRedis, "--protocol", "tcp", "--port", "6380", "--source-group", $sgBackend, "--region", $Region)

    Write-Host "`n==> VPC endpoints (novos)" -ForegroundColor Cyan
    $s3Svc = "com.amazonaws.$Region.s3"
    $ddbSvc = "com.amazonaws.$Region.dynamodb"
    if (-not (Test-VpcEndpointGatewayExists $vpcId $s3Svc)) {
        Invoke-AwsIgnoreGatewayEndpointConflict @("ec2", "create-vpc-endpoint", "--vpc-id", $vpcId, "--service-name", $s3Svc, "--route-table-ids", $pubRt, $privRt, "--region", $Region, "--tag-specifications", 'ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=bellx-vpce-s3}]')
    } else { Write-Host "  VPCE S3 ja existe - pulando." }
    if (-not (Test-VpcEndpointGatewayExists $vpcId $ddbSvc)) {
        Invoke-AwsIgnoreGatewayEndpointConflict @("ec2", "create-vpc-endpoint", "--vpc-id", $vpcId, "--service-name", $ddbSvc, "--route-table-ids", $pubRt, $privRt, "--region", $Region, "--tag-specifications", 'ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=bellx-vpce-dynamodb}]')
    } else { Write-Host "  VPCE DynamoDB ja existe - pulando." }

    $ifaceServices = @(
        "com.amazonaws.$Region.ssm",
        "com.amazonaws.$Region.ssmmessages",
        "com.amazonaws.$Region.ec2messages",
        "com.amazonaws.$Region.ecr.api",
        "com.amazonaws.$Region.ecr.dkr",
        "com.amazonaws.$Region.logs",
        "com.amazonaws.$Region.elasticache"
    )
    foreach ($svc in $ifaceServices) {
        $short = ($svc -split '\.')[-1]
        if (Test-VpcEndpointInterfaceExists $vpcId $svc) {
            Write-Host ('  VPCE ' + $short + ' ja existe - pulando.')
            continue
        }
        $tagVpce = 'ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=bellx-vpce-' + $short + '}]'
        Invoke-Aws @(
            "ec2", "create-vpc-endpoint",
            "--vpc-id", $vpcId,
            "--vpc-endpoint-type", "Interface",
            "--service-name", $svc,
            "--subnet-ids", $privateSubnets[0], $privateSubnets[1],
            "--security-group-ids", $sgEndpoints,
            "--private-dns-enabled",
            "--region", $Region,
            "--tag-specifications", $tagVpce
        )
    }
} else {
    Write-Host ''
    Write-Host ('==> VPC existente: ' + $vpcId + ' (descobrindo recursos)') -ForegroundColor Cyan
    Invoke-Aws @("ec2", "modify-vpc-attribute", "--vpc-id", $vpcId, "--enable-dns-hostnames", "--region", $Region)
    Invoke-Aws @("ec2", "modify-vpc-attribute", "--vpc-id", $vpcId, "--enable-dns-support", "--region", $Region)

    $igwJson = Invoke-Aws @('ec2', 'describe-internet-gateways', '--region', $Region, '--filters', "Name=attachment.vpc-id,Values=$vpcId", '--output', 'json') | ConvertFrom-Json
    if ($igwJson.InternetGateways.Count -ge 1) {
        $igwId = $igwJson.InternetGateways[0].InternetGatewayId
    }

    $snJson = Invoke-Aws @('ec2', 'describe-subnets', '--region', $Region, '--filters', "Name=vpc-id,Values=$vpcId", '--output', 'json') | ConvertFrom-Json
    $pubList = @($snJson.Subnets | Where-Object { $_.MapPublicIpOnLaunch -eq $true } | Sort-Object { $_.CidrBlock })
    $privList = @($snJson.Subnets | Where-Object { -not $_.MapPublicIpOnLaunch } | Sort-Object { $_.CidrBlock })
    if ($pubList.Count -lt 2 -or $privList.Count -lt 2) {
        throw "VPC $vpcId : esperadas 2 subnets publicas e 2 privadas. Encontrado: $($pubList.Count) pub, $($privList.Count) priv."
    }
    $publicSubnets = @($pubList[0].SubnetId, $pubList[1].SubnetId)
    $privateSubnets = @($privList[0].SubnetId, $privList[1].SubnetId)

    $rtJson = Invoke-Aws @('ec2', 'describe-route-tables', '--region', $Region, '--filters', "Name=vpc-id,Values=$vpcId", '--output', 'json') | ConvertFrom-Json
    foreach ($rt in $rtJson.RouteTables) {
        $n = ($rt.Tags | Where-Object { $_.Key -eq 'Name' } | Select-Object -ExpandProperty Value -First 1)
        if ($n -eq 'bellx-rt-public') { $pubRt = $rt.RouteTableId }
        if ($n -eq 'bellx-rt-private') { $privRt = $rt.RouteTableId }
    }
    if (-not $pubRt -or -not $privRt) {
        throw "VPC $vpcId : route tables bellx-rt-public / bellx-rt-private nao encontradas."
    }

    foreach ($pair in @(
        @{ Name = 'bellx-endpoints-sg'; Var = 'sgEndpoints' },
        @{ Name = 'bellx-redis-sg'; Var = 'sgRedis' },
        @{ Name = 'bellx-alb-sg'; Var = 'sgAlb' },
        @{ Name = 'bellx-backend-sg'; Var = 'sgBackend' }
    )) {
        $gid = Get-SgIdInVpc $vpcId $pair.Name
        if (-not $gid) {
            throw "Security group $($pair.Name) nao encontrada na VPC $vpcId."
        }
        Set-Variable -Name $pair.Var -Value $gid -Scope Script
    }

    Write-Host "`n==> Regras SG (idempotente; trafego ALB -> container na porta $ContainerPort)" -ForegroundColor Cyan
    Invoke-AwsIgnoreDuplicate @("ec2", "authorize-security-group-ingress", "--group-id", $sgEndpoints, "--protocol", "tcp", "--port", "443", "--cidr", $VpcCidr, "--region", $Region)
    Invoke-AwsIgnoreDuplicate @("ec2", "authorize-security-group-ingress", "--group-id", $sgAlb, "--protocol", "tcp", "--port", "80", "--cidr", "0.0.0.0/0", "--region", $Region)
    Invoke-AwsIgnoreDuplicate @("ec2", "authorize-security-group-ingress", "--group-id", $sgAlb, "--protocol", "tcp", "--port", "443", "--cidr", "0.0.0.0/0", "--region", $Region)
    Invoke-AwsIgnoreDuplicate @("ec2", "authorize-security-group-ingress", "--group-id", $sgBackend, "--protocol", "tcp", "--port", $ContainerPort, "--source-group", $sgAlb, "--region", $Region)
    Invoke-AwsIgnoreDuplicate @("ec2", "authorize-security-group-ingress", "--group-id", $sgRedis, "--protocol", "tcp", "--port", "6379", "--source-group", $sgBackend, "--region", $Region)
    Invoke-AwsIgnoreDuplicate @("ec2", "authorize-security-group-ingress", "--group-id", $sgRedis, "--protocol", "tcp", "--port", "6380", "--source-group", $sgBackend, "--region", $Region)

    Write-Host "`n==> VPC endpoints (garantir)" -ForegroundColor Cyan
    $s3Svc = "com.amazonaws.$Region.s3"
    $ddbSvc = "com.amazonaws.$Region.dynamodb"
    if (-not (Test-VpcEndpointGatewayExists $vpcId $s3Svc)) {
        Invoke-AwsIgnoreGatewayEndpointConflict @("ec2", "create-vpc-endpoint", "--vpc-id", $vpcId, "--service-name", $s3Svc, "--route-table-ids", $pubRt, $privRt, "--region", $Region, "--tag-specifications", 'ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=bellx-vpce-s3}]')
    } else { Write-Host "  VPCE S3 OK" }
    if (-not (Test-VpcEndpointGatewayExists $vpcId $ddbSvc)) {
        Invoke-AwsIgnoreGatewayEndpointConflict @("ec2", "create-vpc-endpoint", "--vpc-id", $vpcId, "--service-name", $ddbSvc, "--route-table-ids", $pubRt, $privRt, "--region", $Region, "--tag-specifications", 'ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=bellx-vpce-dynamodb}]')
    } else { Write-Host "  VPCE DynamoDB OK" }

    $ifaceServices = @(
        "com.amazonaws.$Region.ssm",
        "com.amazonaws.$Region.ssmmessages",
        "com.amazonaws.$Region.ec2messages",
        "com.amazonaws.$Region.ecr.api",
        "com.amazonaws.$Region.ecr.dkr",
        "com.amazonaws.$Region.logs",
        "com.amazonaws.$Region.elasticache"
    )
    foreach ($svc in $ifaceServices) {
        $short = ($svc -split '\.')[-1]
        if (Test-VpcEndpointInterfaceExists $vpcId $svc) {
            Write-Host ('  VPCE ' + $short + ' OK')
            continue
        }
        $tagVpce = 'ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=bellx-vpce-' + $short + '}]'
        Invoke-Aws @(
            "ec2", "create-vpc-endpoint",
            "--vpc-id", $vpcId,
            "--vpc-endpoint-type", "Interface",
            "--service-name", $svc,
            "--subnet-ids", $privateSubnets[0], $privateSubnets[1],
            "--security-group-ids", $sgEndpoints,
            "--private-dns-enabled",
            "--region", $Region,
            "--tag-specifications", $tagVpce
        )
    }
}

# --- ElastiCache ---
Write-Host "`n==> ElastiCache Serverless (Valkey)" -ForegroundColor Cyan
$cacheName = "bellx-redis-cache"
$cacheExists = Invoke-AwsQuiet @('elasticache', 'describe-serverless-caches', '--serverless-cache-name', $cacheName, '--region', $Region, '--query', 'ServerlessCaches[0].ServerlessCacheName', '--output', 'text')
if ($cacheExists -eq $cacheName) {
    Write-Host ('Cache ' + $cacheName + ' ja existe - pulando create.')
} else {
    Invoke-Aws @(
        "elasticache", "create-serverless-cache",
        "--serverless-cache-name", $cacheName,
        "--engine", "valkey",
        "--major-engine-version", "8",
        "--description", "BellX Valkey",
        "--subnet-ids", $privateSubnets[0], $privateSubnets[1],
        "--security-group-ids", $sgRedis,
        "--region", $Region
    )
    Write-Host 'Aguardando cache disponivel...'
    do {
        Start-Sleep -Seconds 20
        $st = Invoke-AwsQuiet @('elasticache', 'describe-serverless-caches', '--serverless-cache-name', $cacheName, '--region', $Region, '--query', 'ServerlessCaches[0].Status', '--output', 'text')
        Write-Host ('  Status: ' + $st)
    } while ($st -and $st -ne "available" -and $st -ne "create-failed")
    if ($st -eq "create-failed") { throw "ElastiCache Serverless falhou." }
}

$redisEndpoint = Invoke-AwsQuiet @('elasticache', 'describe-serverless-caches', '--serverless-cache-name', $cacheName, '--region', $Region, '--query', 'ServerlessCaches[0].Endpoint.Address', '--output', 'text')
if ([string]::IsNullOrWhiteSpace($redisEndpoint) -or $redisEndpoint -eq 'None') { $redisEndpoint = '' }

# --- ECS cluster ---
Write-Host "`n==> ECS cluster" -ForegroundColor Cyan
$clArn = Invoke-AwsQuiet @('ecs', 'describe-clusters', '--region', $Region, '--clusters', 'bellx-cluster', '--query', 'clusters[0].clusterArn', '--output', 'text')
if ([string]::IsNullOrWhiteSpace($clArn) -or $clArn -eq 'None') {
    Invoke-Aws @("ecs", "create-cluster", "--cluster-name", "bellx-cluster", "--region", $Region)
    Write-Host "Cluster bellx-cluster criado."
} else {
    Write-Host "Cluster bellx-cluster ja existe."
}

# --- S3 ---
Write-Host "`n==> S3 buckets" -ForegroundColor Cyan
$bucketNames = @()
$baseBuckets = @("bellx-site-images", "bellx-site-static", "bellx-site-videos")
foreach ($base in $baseBuckets) {
    $name = "$base$BucketSuffix"
    $bucketNames += $name
    if (Test-S3BucketExists $name) {
        Write-Host ('Bucket ja existe: ' + $name)
    } else {
        $cfg = '{"LocationConstraint":"sa-east-1"}'
        Invoke-Aws @('s3api', 'create-bucket', '--bucket', $name, '--region', $Region, '--create-bucket-configuration', $cfg)
        Write-Host ('Criado: ' + $name)
    }
    try {
        Invoke-Aws @("s3api", "put-public-access-block", "--bucket", $name, "--public-access-block-configuration", "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true", "--region", $Region)
    } catch {
        Write-Host ('  (public-access-block: ' + $_.Exception.Message + ')')
    }
}

# --- ECR ---
Write-Host "`n==> ECR" -ForegroundColor Cyan
$ecrUri = "${AccountId}.dkr.ecr.${Region}.amazonaws.com/${EcrRepositoryName}"
try {
    Invoke-Aws @('ecr', 'create-repository', '--repository-name', $EcrRepositoryName, '--region', $Region, '--image-scanning-configuration', 'scanOnPush=true')
    Write-Host ('Repositorio criado: ' + $EcrRepositoryName)
} catch {
    $m = $_.Exception.Message
    if ($m -match 'RepositoryAlreadyExistsException|already exists') {
        Write-Host 'Repositorio ECR ja existe.'
    } else { throw }
}

# --- DynamoDB ---
Write-Host "`n==> DynamoDB (tabelas do JSON)" -ForegroundColor Cyan
$dynamoTableNames = @()
if (Test-Path -LiteralPath $DynamoDbSpecPath) {
    $spec = Get-Content -LiteralPath $DynamoDbSpecPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($t in $spec.tables) {
        $tn = $t.TableName
        $pk = $t.PartitionKey
        $dynamoTableNames += $tn
        if (Test-DynamoTableExists $tn) {
            Write-Host ("Tabela ja existe: " + $tn)
        } else {
            Invoke-Aws @(
                'dynamodb', 'create-table',
                '--table-name', $tn,
                '--billing-mode', 'PAY_PER_REQUEST',
                '--attribute-definitions', "AttributeName=$($pk.Name),AttributeType=$($pk.Type)",
                '--key-schema', "AttributeName=$($pk.Name),KeyType=HASH",
                '--region', $Region
            )
            Write-Host ("Criada tabela: " + $tn)
        }
    }
} else {
    Write-Host "  (ficheiro nao encontrado: $DynamoDbSpecPath - pulando DynamoDB)"
}

# --- SSM (Redis / referencias) ---
Write-Host "`n==> SSM Parameter Store (/bellx/*)" -ForegroundColor Cyan
if ($redisEndpoint) {
    try {
        Invoke-Aws @('ssm', 'put-parameter', '--name', '/bellx/redis/endpoint', '--value', $redisEndpoint, '--type', 'String', '--overwrite', '--region', $Region)
    } catch { Write-Host '  /bellx/redis/endpoint (put-parameter falhou ou sem permissao)' }
    try {
        Invoke-Aws @('ssm', 'put-parameter', '--name', '/bellx/redis/port', '--value', '6379', '--type', 'String', '--overwrite', '--region', $Region)
    } catch { }
    try {
        Invoke-Aws @('ssm', 'put-parameter', '--name', '/bellx/redis/tls-port', '--value', '6380', '--type', 'String', '--overwrite', '--region', $Region)
    } catch { }
    Write-Host 'Parametros Redis gravados em /bellx/redis/*'
} else {
    Write-Host '  (endpoint Redis vazio - pulando SSM Redis)'
}
foreach ($tn in $dynamoTableNames) {
    try {
        Invoke-Aws @('ssm', 'put-parameter', '--name', ("/bellx/dynamodb/table/" + $tn), '--value', $tn, '--type', 'String', '--overwrite', '--region', $Region)
    } catch { }
}

# --- CloudWatch Logs ---
$logGroup = "/ecs/$TaskDefinitionFamily"
Write-Host "`n==> CloudWatch Logs: $logGroup" -ForegroundColor Cyan
try {
    Invoke-Aws @('logs', 'create-log-group', '--log-group-name', $logGroup, '--region', $Region)
} catch {
    if ($_.Exception.Message -notmatch 'ResourceAlreadyExistsException|already exists') { Write-Host '  (log group pode ja existir)' }
}

# --- ALB + Target Group ---
Write-Host "`n==> ALB + Target Group" -ForegroundColor Cyan
$tgArn = $null
$oldEap = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
$tgRaw = & aws elbv2 describe-target-groups --region $Region --names $TargetGroupName --output json 2>&1
$ErrorActionPreference = $oldEap
if ($LASTEXITCODE -eq 0 -and $tgRaw) {
    try {
        $tgArn = (($tgRaw | ConvertFrom-Json).TargetGroups[0].TargetGroupArn)
    } catch { $tgArn = $null }
}
if (-not $tgArn) {
    $tgOut = Invoke-Aws @(
        'elbv2', 'create-target-group',
        '--name', $TargetGroupName,
        '--protocol', 'HTTP',
        '--port', $ContainerPort.ToString(),
        '--vpc-id', $vpcId,
        '--target-type', 'ip',
        '--health-check-path', $HealthCheckPath,
        '--health-check-protocol', 'HTTP',
        '--region', $Region
    ) | ConvertFrom-Json
    $tgArn = $tgOut.TargetGroups[0].TargetGroupArn
    Write-Host ('Target group criada: ' + $TargetGroupName)
} else {
    Write-Host 'Target group ja existe.'
}

$allAlb = Invoke-Aws @('elbv2', 'describe-load-balancers', '--region', $Region, '--output', 'json') | ConvertFrom-Json
$albObj = $allAlb.LoadBalancers | Where-Object { $_.LoadBalancerName -eq $AlbName } | Select-Object -First 1
$albArn = $null
$albDns = ''
if (-not $albObj) {
    $albOut = Invoke-Aws @(
        'elbv2', 'create-load-balancer',
        '--name', $AlbName,
        '--type', 'application',
        '--scheme', 'internet-facing',
        '--ip-address-type', 'ipv4',
        '--subnets', $publicSubnets[0], $publicSubnets[1],
        '--security-groups', $sgAlb,
        '--region', $Region,
        '--tags', "Key=Name,Value=$AlbName"
    ) | ConvertFrom-Json
    $albArn = $albOut.LoadBalancers[0].LoadBalancerArn
    $albDns = $albOut.LoadBalancers[0].DNSName
    Write-Host ('ALB criado: ' + $albDns)
} else {
    $albArn = $albObj.LoadBalancerArn
    $albDns = $albObj.DNSName
    Write-Host ('ALB ja existe: ' + $albDns)
}

$lis = Invoke-Aws @('elbv2', 'describe-listeners', '--region', $Region, '--load-balancer-arn', $albArn, '--output', 'json') | ConvertFrom-Json
$hasL80 = @($lis.Listeners | Where-Object { $_.Port -eq 80 }).Count -gt 0
if (-not $hasL80) {
    Invoke-Aws @(
        'elbv2', 'create-listener',
        '--load-balancer-arn', $albArn,
        '--protocol', 'HTTP',
        '--port', '80',
        '--default-actions', "Type=forward,TargetGroupArn=$tgArn",
        '--region', $Region
    )
    Write-Host 'Listener HTTP 80 -> target group'
} else {
    Write-Host 'Listener 80 ja existe.'
}

if ($AcmCertificateArn) {
    $lis = Invoke-Aws @('elbv2', 'describe-listeners', '--region', $Region, '--load-balancer-arn', $albArn, '--output', 'json') | ConvertFrom-Json
    $hasL443 = @($lis.Listeners | Where-Object { $_.Port -eq 443 }).Count -gt 0
    if (-not $hasL443) {
        Invoke-Aws @(
            'elbv2', 'create-listener',
            '--load-balancer-arn', $albArn,
            '--protocol', 'HTTPS',
            '--port', '443',
            '--certificates', "CertificateArn=$AcmCertificateArn",
            '--default-actions', "Type=forward,TargetGroupArn=$tgArn",
            '--region', $Region
        )
        Write-Host 'Listener HTTPS 443 -> target group'
    } else {
        Write-Host 'Listener 443 ja existe.'
    }
} else {
    Write-Host '(Sem -AcmCertificateArn: HTTPS nao configurado; certificado ACM na mesma regiao do ALB.)'
}

# --- Task definition + ECS service (imagem obrigatoria) ---
$taskDefArn = $null
if ($BackendImageUri) {
    Write-Host "`n==> ECS Task Definition + Service" -ForegroundColor Cyan
    $taskJson = [ordered]@{
        family                   = $TaskDefinitionFamily
        networkMode              = 'awsvpc'
        requiresCompatibilities  = @('FARGATE')
        cpu                      = '256'
        memory                   = '512'
        executionRoleArn         = $execRoleArn
        taskRoleArn              = $taskRoleArn
        containerDefinitions     = @(
            @{
                name              = $TaskDefinitionFamily
                image             = $BackendImageUri
                essential         = $true
                portMappings      = @(@{ containerPort = $ContainerPort; protocol = 'tcp' })
                logConfiguration  = @{
                    logDriver = 'awslogs'
                    options   = @{
                        'awslogs-group'         = $logGroup
                        'awslogs-region'        = $Region
                        'awslogs-stream-prefix' = 'ecs'
                    }
                }
            }
        )
    }
    $taskPath = Join-Path $env:TEMP "bellx-taskdef.json"
    ($taskJson | ConvertTo-Json -Depth 8 -Compress) | Set-Content -Path $taskPath -Encoding UTF8
    $taskFileUri = 'file://' + ((Resolve-Path $taskPath).Path -replace '\\', '/')
    $reg = Invoke-Aws @('ecs', 'register-task-definition', '--region', $Region, '--cli-input-json', $taskFileUri) | ConvertFrom-Json
    $taskDefArn = $reg.taskDefinition.taskDefinitionArn
    Write-Host ('Task definition registada: ' + $taskDefArn)

    $svcDesc = Invoke-Aws @('ecs', 'describe-services', '--region', $Region, '--cluster', 'bellx-cluster', '--services', $EcsServiceName, '--output', 'json') | ConvertFrom-Json
    $svcMissing = ($svcDesc.failures | Where-Object { $_.reason -eq 'MISSING' }).Count -gt 0
    $svcActive = ($svcDesc.services.Count -gt 0 -and $svcDesc.services[0].status -eq 'ACTIVE')
    $netCfg = "awsvpcConfiguration={subnets=[$($privateSubnets[0]),$($privateSubnets[1])],securityGroups=[$sgBackend],assignPublicIp=DISABLED}"
    $lbCfg = "targetGroupArn=$tgArn,containerName=$TaskDefinitionFamily,containerPort=$ContainerPort"

    if ($svcActive) {
        Write-Host "Service $EcsServiceName ja ACTIVE (nao atualizado). Para novo deploy: aws ecs update-service --force-new-deployment ..."
    } elseif ($svcMissing -or $svcDesc.services.Count -eq 0) {
        Invoke-Aws @(
            'ecs', 'create-service',
            '--region', $Region,
            '--cluster', 'bellx-cluster',
            '--service-name', $EcsServiceName,
            '--task-definition', $taskDefArn,
            '--desired-count', '1',
            '--launch-type', 'FARGATE',
            '--platform-version', 'LATEST',
            '--network-configuration', $netCfg,
            '--load-balancers', $lbCfg,
            '--health-check-grace-period-seconds', '90'
        )
        Write-Host "Service $EcsServiceName criado."
    } else {
        Write-Host ('Service existe com status: ' + $svcDesc.services[0].status + ' - nao alterado automaticamente.')
    }
} else {
    Write-Host ''
    Write-Host 'Pulando Task Definition / ECS Service (passe -BackendImageUri, ex.: ACCOUNT.dkr.ecr.sa-east-1.amazonaws.com/bellx-backend:tag)' -ForegroundColor Yellow
}

$out = [ordered]@{
    Region              = $Region
    AccountId           = $AccountId
    VpcId               = $vpcId
    PublicSubnets       = $publicSubnets
    PrivateSubnets      = $privateSubnets
    InternetGatewayId   = $igwId
    RouteTablePublic    = $pubRt
    RouteTablePrivate   = $privRt
    SgEndpoints         = $sgEndpoints
    SgRedis             = $sgRedis
    SgAlb               = $sgAlb
    SgBackend           = $sgBackend
    ElastiCacheName     = $cacheName
    RedisEndpoint       = $redisEndpoint
    EcrRepositoryUri    = $ecrUri
    EcsCluster          = "bellx-cluster"
    AlbDnsName          = $albDns
    AlbArn              = $albArn
    TargetGroupArn      = $tgArn
    TaskDefinitionArn   = $taskDefArn
    EcsServiceName      = $EcsServiceName
    S3Buckets           = $bucketNames
    DynamoDbTables      = $dynamoTableNames
    IamBackendRole      = "bellx-backend-role"
    IamExecutionRole    = "bellx-ecs-task-execution-role"
}
$outPath = Join-Path $PSScriptRoot "bellx-sa-east-1-outputs.json"
$out | ConvertTo-Json -Depth 8 | Set-Content -Path $outPath -Encoding UTF8
Write-Host ''
Write-Host ('IDs salvos em: ' + $outPath) -ForegroundColor Green
Write-Host 'CloudFront na frente dos buckets S3: configurar OAC + politicas S3 (CLI e longo; Terraform ou console sao praticos).' -ForegroundColor Yellow
Write-Host 'Segredos (JWT, etc.): Secrets Manager ou SSM SecureString - nao commitar.' -ForegroundColor Yellow
