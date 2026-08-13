param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$DevDir = Join-Path $Root 'infra\dev'
$EnvFile = Join-Path $DevDir '.env'

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

if ((Test-Path -LiteralPath $EnvFile) -and -not $Force) {
    $existing = Get-Content -LiteralPath $EnvFile -Encoding UTF8
    $updated = $false
    $adminSecretEntries = @($existing | Where-Object { $_ -match '^\s*ADMIN_SECURITY_SECRET=' })
    if ($adminSecretEntries.Count -gt 1) {
        throw 'infra/dev/.env contains duplicate ADMIN_SECURITY_SECRET entries. Keep exactly one value before retrying.'
    }
    if ($adminSecretEntries.Count -eq 0) {
        Add-Content -LiteralPath $EnvFile -Value "ADMIN_SECURITY_SECRET=$(New-HexSecret 32)" -Encoding UTF8
        $updated = $true
    } else {
        $adminSecretValue = ($adminSecretEntries[0] -split '=', 2)[1].Trim()
        if ($adminSecretValue.Length -lt 32) {
            $replacement = "ADMIN_SECURITY_SECRET=$(New-HexSecret 32)"
            $existing = @($existing | ForEach-Object {
                if ($_ -match '^\s*ADMIN_SECURITY_SECRET=') { $replacement } else { $_ }
            })
            [System.IO.File]::WriteAllLines($EnvFile, $existing, [System.Text.UTF8Encoding]::new($false))
            $updated = $true
        }
    }
    if (-not ($existing | Where-Object { $_ -match '^\s*TELEGRAM_BOT_TOKEN=' })) {
        Add-Content -LiteralPath $EnvFile -Value @(
            '# Optional: paste a Telegram Bot token to enable server-relayed sticker pack imports.'
            'TELEGRAM_BOT_TOKEN='
        ) -Encoding UTF8
        $updated = $true
    }
    if ($updated) {
        Write-Host "Development environment upgraded in place: $EnvFile"
        Write-Host 'Existing valid credentials were preserved; missing or invalid development settings were repaired.'
    } else {
        Write-Host "Development environment already exists and is current: $EnvFile"
    }
    Write-Host 'Use -Force only if you intentionally want to rotate all local development credentials.'
    exit 0
}

$postgresPassword = New-HexSecret 24
$redisPassword = New-HexSecret 24
$minioPassword = New-HexSecret 24
$liveKitKey = 'dddev_' + (New-HexSecret 8)
$liveKitSecret = New-HexSecret 32
$authTokenSecret = New-HexSecret 32
$adminSecuritySecret = New-HexSecret 32
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
    "ADMIN_SECURITY_SECRET=$adminSecuritySecret"
    "EMAIL_CODE_PEPPER=$emailCodePepper"
    '# Optional: paste a Telegram Bot token to enable server-relayed sticker pack imports.'
    'TELEGRAM_BOT_TOKEN='
) -join "`n"

New-Item -ItemType Directory -Path $DevDir -Force | Out-Null
[System.IO.File]::WriteAllText($EnvFile, $content + "`n", [System.Text.UTF8Encoding]::new($false))

Write-Host 'Local development credentials generated.'
Write-Host "File: $EnvFile"
Write-Host 'Secrets were not printed to the terminal.'
Write-Host 'This file is ignored by Git.'
