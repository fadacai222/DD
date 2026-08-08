$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$RestoreMarker = Join-Path $Root '.data\restore-realtime-after-call-poc.flag'
$LanStateFile = Join-Path $Root '.data\call-poc-lan.json'

if (Test-Path -LiteralPath $LanStateFile) {
    & (Join-Path $PSScriptRoot 'stop-call-poc-lan.ps1')
    exit $LASTEXITCODE
}

Push-Location $Root
try {
    & docker compose -f compose.call-poc.yml down --remove-orphans
    if ($LASTEXITCODE -ne 0) { throw 'Call PoC services failed to stop.' }

    if (Test-Path -LiteralPath $RestoreMarker) {
        & docker compose -f compose.poc.yml up -d --build
        if ($LASTEXITCODE -ne 0) { throw 'Previous realtime PoC failed to restore.' }
        Remove-Item -LiteralPath $RestoreMarker -Force
        Write-Host 'Call PoC stopped; previous realtime PoC restored.'
    }
    else {
        Write-Host 'Call PoC services stopped.'
    }
}
finally {
    Pop-Location
}
