param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$DevDir = Join-Path $Root 'infra\dev'
$EnvFile = Join-Path $DevDir '.env'

if ((Test-Path -LiteralPath $EnvFile) -and -not $Force) {
    Write-Host "Development environment already exists: $EnvFile"
    Write-Host 'Use -Force only if you intentionally want to rotate all local development credentials.'
    exit 0
}

function New-HexSecret {
    param([int]$Bytes = 24)

    $buffer = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($buffer)
    }
    finally {
        $rng.Dispose()
    }
    return ([System.BitConverter]::ToString($buffer) -replace '-', '').ToLowerInvariant()
}

$postgresPassword = New-HexSecret 24
$redisPassword = New-HexSecret 24
$minioPassword = New-HexSecret 24
$liveKitKey = 'dddev_' + (New-HexSecret 8)
$liveKitSecret = New-HexSecret 32
$authTokenSecret = New-HexSecret 32
$emailCodePepper = New-HexSecret 32

$content = @(
    'DD_POSTGRES_DB=dd'
    'DD_POSTGRES_USER=dd'
    "DD_POSTGRES_PASSWORD=$postgresPassword"
    "DD_REDIS_PASSWORD=$redisPassword"
    'DD_MINIO_ROOT_USER=ddadmin'
    "DD_MINIO_ROOT_PASSWORD=$minioPassword"
    "DD_LIVEKIT_API_KEY=$liveKitKey"
    "DD_LIVEKIT_API_SECRET=$liveKitSecret"
    "AUTH_TOKEN_SECRET=$authTokenSecret"
    "EMAIL_CODE_PEPPER=$emailCodePepper"
) -join "`n"

New-Item -ItemType Directory -Path $DevDir -Force | Out-Null
[System.IO.File]::WriteAllText($EnvFile, $content + "`n", [System.Text.UTF8Encoding]::new($false))

Write-Host 'Local development credentials generated.'
Write-Host "File: $EnvFile"
Write-Host 'Secrets were not printed to the terminal.'
Write-Host 'This file is ignored by Git.'
