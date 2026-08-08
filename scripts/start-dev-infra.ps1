param(
    [switch]$Pull
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$DevDir = Join-Path $Root 'infra\dev'
$ComposeFile = Join-Path $DevDir 'compose.yml'
$EnvFile = Join-Path $DevDir '.env'

if (-not (Test-Path -LiteralPath $EnvFile)) {
    throw 'Missing infra\dev\.env. Run .\scripts\init-dev-env.ps1 first.'
}

& docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'Docker Desktop is not running.'
}

Push-Location $DevDir
try {
    & docker compose --env-file $EnvFile -f $ComposeFile config --quiet
    if ($LASTEXITCODE -ne 0) {
        throw 'Development Compose configuration is invalid.'
    }

    if ($Pull) {
        & docker compose --env-file $EnvFile -f $ComposeFile pull
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to pull development images.'
        }
    }

    & docker compose --env-file $EnvFile -f $ComposeFile up -d
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to start development infrastructure.'
    }

    Write-Host ''
    Write-Host 'Development infrastructure started.'
    Write-Host 'PostgreSQL: 127.0.0.1:15432'
    Write-Host 'Redis:      127.0.0.1:16379'
    Write-Host 'MinIO API:  http://127.0.0.1:19000'
    Write-Host 'MinIO UI:   http://127.0.0.1:19001'
    Write-Host 'Mailpit UI: http://127.0.0.1:18025'
    Write-Host 'Mailpit SMTP: 127.0.0.1:11025'
    Write-Host 'LiveKit:    ws://127.0.0.1:17880'
    Write-Host ''
    Write-Host 'Run .\scripts\test-dev-infra.ps1 to verify health.'
} finally {
    Pop-Location
}
