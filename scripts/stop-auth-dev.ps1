$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$StateFile = Join-Path $Root '.data\auth-dev.json'
$ComposeFile = Join-Path $Root 'infra\dev\compose.yml'
$EnvFile = Join-Path $Root 'infra\dev\.env'
$StopWebScript = Join-Path $PSScriptRoot 'stop-web-client.ps1'
$FirewallScript = Join-Path $PSScriptRoot 'configure-auth-dev-firewall.ps1'
$ApiExe = Join-Path $Root '.data\dd-auth-dev-api.exe'
$ApiOut = Join-Path $Root '.data\dd-auth-dev-api.out.log'
$ApiErr = Join-Path $Root '.data\dd-auth-dev-api.err.log'
$WorkerExe = Join-Path $Root '.data\dd-auth-dev-worker.exe'
$WorkerOut = Join-Path $Root '.data\dd-auth-dev-worker.out.log'
$WorkerErr = Join-Path $Root '.data\dd-auth-dev-worker.err.log'

if (-not (Test-Path -LiteralPath $StateFile)) {
    Write-Host 'P2 Auth dev state file not found; nothing to stop.'
    exit 0
}

$state = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json

$apiPid = [int]$state.apiPid
if ($apiPid -gt 0) {
    $process = Get-Process -Id $apiPid -ErrorAction SilentlyContinue
    if ($null -ne $process) {
        Stop-Process -Id $apiPid -Force -ErrorAction SilentlyContinue
        try { $process.WaitForExit(5000) | Out-Null } catch {}
    }
}

$workerPid = 0
if ($state.PSObject.Properties.Name -contains 'workerPid') {
    $workerPid = [int]$state.workerPid
}
if ($workerPid -gt 0) {
    $process = Get-Process -Id $workerPid -ErrorAction SilentlyContinue
    if ($null -ne $process) {
        Stop-Process -Id $workerPid -Force -ErrorAction SilentlyContinue
        try { $process.WaitForExit(5000) | Out-Null } catch {}
    }
}

if ([bool]$state.webStartedByScript) {
    & $StopWebScript
}

if (Test-Path -LiteralPath $EnvFile) {
    if ([bool]$state.postgresStartedByScript) {
        & docker compose --env-file $EnvFile -f $ComposeFile stop postgres
    }
    if ([bool]$state.mailpitStartedByScript) {
        & docker compose --env-file $EnvFile -f $ComposeFile stop mailpit
    }
    if (($state.PSObject.Properties.Name -contains 'redisStartedByScript') -and [bool]$state.redisStartedByScript) {
        & docker compose --env-file $EnvFile -f $ComposeFile stop redis
    }
}

$lanIP = [string]$state.lanIP
if (-not [string]::IsNullOrWhiteSpace($lanIP)) {
    & $FirewallScript -LanIP $lanIP -Remove
}

Remove-Item -LiteralPath $StateFile, $ApiExe, $ApiOut, $ApiErr, $WorkerExe, $WorkerOut, $WorkerErr -Force -ErrorAction SilentlyContinue

Write-Host 'P2 Auth dev environment stopped.'
Write-Host 'PostgreSQL volume is preserved so registered test accounts survive the next start.'
