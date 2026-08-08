$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$StateDir = Join-Path $Root '.data'
$RestoreMarker = Join-Path $StateDir 'restore-realtime-after-call-poc.flag'
$LanStateFile = Join-Path $StateDir 'call-poc-lan.json'
$StoppedRealtime = $false

if (Test-Path -LiteralPath $LanStateFile) {
    throw 'LAN Call PoC is still active or was not cleaned up. Run .\scripts\stop-call-poc-lan.ps1 before starting localhost mode.'
}

& docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'Docker Desktop is not running. Start it and rerun this script.'
}

Push-Location $Root
try {
    $runningName = & docker ps --filter 'name=selfhosted-im-poc-realtime-api-1' --format '{{.Names}}'
    if ($runningName -contains 'selfhosted-im-poc-realtime-api-1') {
        & docker compose -f compose.poc.yml down --remove-orphans
        if ($LASTEXITCODE -ne 0) { throw 'Existing realtime PoC failed to stop.' }
        $StoppedRealtime = $true
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
        Set-Content -LiteralPath $RestoreMarker -Value 'restore' -Encoding ASCII
    }

    & docker compose -f compose.call-poc.yml up -d --build
    if ($LASTEXITCODE -ne 0) { throw 'Call PoC services failed to start.' }

    Write-Host 'Call PoC services started:'
    Write-Host '  Call API:  http://127.0.0.1:18473/api/calls'
    Write-Host '  Token API: http://127.0.0.1:18473/api/calls/token'
    Write-Host '  LiveKit:   ws://127.0.0.1:7880'
    Write-Host '  RTC TCP:   127.0.0.1:7881'
    Write-Host '  RTC UDP:   127.0.0.1:7882/udp'
    Write-Host '  TURN UDP:  127.0.0.1:3478/udp'
    if ($StoppedRealtime) {
        Write-Host 'The previous realtime PoC was paused and will be restored by stop-call-poc.ps1.'
    }
}
catch {
    & docker compose -f compose.call-poc.yml down --remove-orphans *> $null
    if ($StoppedRealtime) {
        & docker compose -f compose.poc.yml up -d --build
        Remove-Item -LiteralPath $RestoreMarker -Force -ErrorAction SilentlyContinue
    }
    throw
}
finally {
    Pop-Location
}
