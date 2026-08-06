$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot

& docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'Docker Desktop is not running. Start it and rerun this script.'
}

Push-Location $Root
try {
    & docker compose -f compose.poc.yml up -d --build
    if ($LASTEXITCODE -ne 0) { throw 'PoC service failed to start.' }

    Write-Host 'PoC service started:'
    Write-Host '  Health: http://127.0.0.1:18473/health'
    Write-Host '  Version: http://127.0.0.1:18473/version'
    Write-Host '  WebSocket: ws://127.0.0.1:18473/ws'
} finally {
    Pop-Location
}
