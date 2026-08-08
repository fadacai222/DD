$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$BaseCompose = Join-Path $Root 'compose.call-poc.yml'
$LanCompose = Join-Path $Root 'compose.call-poc.lan.yml'
$FirewallScript = Join-Path $PSScriptRoot 'configure-call-poc-lan-firewall.ps1'
$StateFile = Join-Path $Root '.data\call-poc-lan.json'
$RestoreMarker = Join-Path $Root '.data\restore-realtime-after-call-poc.flag'

$LanIP = $null
if (Test-Path -LiteralPath $StateFile) {
    try {
        $state = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $LanIP = [string]$state.lanIP
    }
    catch {
        Write-Warning 'LAN state file is unreadable; Docker services will still be stopped.'
    }
}

Push-Location $Root
try {
    if (-not [string]::IsNullOrWhiteSpace($LanIP)) {
        $env:IM_LAN_IP = $LanIP
        & docker compose -f $BaseCompose -f $LanCompose down --remove-orphans
    }
    else {
        & docker compose -f $BaseCompose down --remove-orphans
    }
    if ($LASTEXITCODE -ne 0) { throw 'LAN Call PoC services failed to stop.' }

    if (Test-Path -LiteralPath $RestoreMarker) {
        & docker compose -f compose.poc.yml up -d --build
        if ($LASTEXITCODE -ne 0) { throw 'Previous realtime PoC failed to restore.' }
        Remove-Item -LiteralPath $RestoreMarker -Force
        Write-Host 'Previous realtime PoC restored.'
    }

    if (-not [string]::IsNullOrWhiteSpace($LanIP)) {
        & $FirewallScript -LanIP $LanIP -Remove
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'LAN services are stopped, but firewall rule cleanup failed.'
        }
    }

    Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    Write-Host 'LAN Call PoC stopped and LAN firewall rules removed.'
}
finally {
    Remove-Item Env:IM_LAN_IP -ErrorAction SilentlyContinue
    Pop-Location
}
