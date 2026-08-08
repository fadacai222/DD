param(
    [string]$LanIP,
    [switch]$SkipWebBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$StateDir = Join-Path $Root '.data'
$CrossStateFile = Join-Path $StateDir 'call-poc-crossplatform.json'
$LanStateFile = Join-Path $StateDir 'call-poc-lan.json'
$WebStateFile = Join-Path $StateDir 'web-client.json'
$RunLanScript = Join-Path $PSScriptRoot 'run-call-poc-lan.ps1'
$StopLanScript = Join-Path $PSScriptRoot 'stop-call-poc-lan.ps1'
$StartWebScript = Join-Path $PSScriptRoot 'start-web-client.ps1'
$StopWebScript = Join-Path $PSScriptRoot 'stop-web-client.ps1'

if (Test-Path -LiteralPath $CrossStateFile) {
    throw 'Cross-platform Call PoC already has an active state file. Stop it first with stop-call-poc-crossplatform.ps1.'
}

New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

$LanWasRunning = Test-Path -LiteralPath $LanStateFile
$WebWasRunning = Test-Path -LiteralPath $WebStateFile
$StartedLan = $false
$StartedWeb = $false

try {
    if (-not $LanWasRunning) {
        if ([string]::IsNullOrWhiteSpace($LanIP)) {
            & $RunLanScript
        }
        else {
            & $RunLanScript -LanIP $LanIP
        }
        if ($LASTEXITCODE -ne 0) {
            throw 'LAN Call PoC failed to start.'
        }
        $StartedLan = $true
    }

    if (-not (Test-Path -LiteralPath $LanStateFile)) {
        throw 'LAN Call PoC state file is missing after startup.'
    }
    $LanState = Get-Content -LiteralPath $LanStateFile -Raw -Encoding UTF8 | ConvertFrom-Json

    if (-not $WebWasRunning) {
        if ($SkipWebBuild) {
            & $StartWebScript -SkipBuild
        }
        else {
            & $StartWebScript
        }
        if ($LASTEXITCODE -ne 0) {
            throw 'Web client failed to start.'
        }
        $StartedWeb = $true
    }

    if (-not (Test-Path -LiteralPath $WebStateFile)) {
        throw 'Web client state file is missing after startup.'
    }
    $WebState = Get-Content -LiteralPath $WebStateFile -Raw -Encoding UTF8 | ConvertFrom-Json

    [pscustomobject]@{
        startedAt = (Get-Date).ToString('o')
        lanIP = [string]$LanState.lanIP
        webPort = [int]$WebState.port
        webPid = [int]$WebState.pid
        startedLan = $StartedLan
        startedWeb = $StartedWeb
        reusedLan = $LanWasRunning
        reusedWeb = $WebWasRunning
    } | ConvertTo-Json | Set-Content -LiteralPath $CrossStateFile -Encoding UTF8

    Write-Host ''
    Write-Host 'Cross-platform Call PoC is ready.'
    Write-Host "  Windows API: http://127.0.0.1:18473"
    Write-Host "  Web page:    http://127.0.0.1:$($WebState.port)"
    Write-Host "  Web API:     http://127.0.0.1:18473"
    Write-Host "  Android API: http://$($LanState.lanIP):18473"
    Write-Host "  LiveKit LAN: ws://$($LanState.lanIP):7880"
    Write-Host "  TURN UDP:    $($LanState.lanIP):3478/udp"
    Write-Host "  TURN relay:  $($LanState.lanIP):30000-30019/udp"
    Write-Host ''
    Write-Host 'Suggested identities:'
    Write-Host '  Windows = alice'
    Write-Host '  Web     = bob'
    Write-Host '  Android = charlie'
    Write-Host ''
    Write-Host 'Test Web <-> Android first, then three-way sequential one-to-one calls.'
    Write-Host 'Stop: powershell -ExecutionPolicy Bypass -File .\scripts\stop-call-poc-crossplatform.ps1'
}
catch {
    if ($StartedWeb) {
        & $StopWebScript *> $null
    }
    if ($StartedLan) {
        & $StopLanScript *> $null
    }
    Remove-Item -LiteralPath $CrossStateFile -Force -ErrorAction SilentlyContinue
    throw
}
