$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot

Push-Location $Root
try {
    & docker compose -f compose.poc.yml down --remove-orphans
    if ($LASTEXITCODE -ne 0) { throw 'PoC service failed to stop.' }
    Write-Host 'PoC service stopped.'
} finally {
    Pop-Location
}
