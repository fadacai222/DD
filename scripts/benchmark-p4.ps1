[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$ComposeFile = Join-Path $Root 'infra\dev\compose.yml'
$EnvFile = Join-Path $Root 'infra\dev\.env'
$ServerDir = Join-Path $Root 'server'

if (-not (Test-Path -LiteralPath $EnvFile)) {
    throw "Missing $EnvFile. Copy infra/dev/.env.example first."
}

function Import-DotEnv {
    param([Parameter(Mandatory)][string]$Path)

    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $parts = $trimmed -split '=', 2
        if ($parts.Count -ne 2) { continue }
        [Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim(), 'Process')
    }
}

function Test-ComposeServiceRunning {
    param([Parameter(Mandatory)][string]$Service)

    $containerId = (& docker compose --env-file $EnvFile -f $ComposeFile ps -q $Service 2>$null)
    if ([string]::IsNullOrWhiteSpace(($containerId -join '').Trim())) { return $false }
    $running = (& docker inspect -f '{{.State.Running}}' $containerId[0] 2>$null)
    return (($running -join '').Trim() -eq 'true')
}

function Wait-ComposeHealthy {
    param(
        [Parameter(Mandatory)][string]$Service,
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $containerId = (& docker compose --env-file $EnvFile -f $ComposeFile ps -q $Service 2>$null)
        if (-not [string]::IsNullOrWhiteSpace(($containerId -join '').Trim())) {
            $status = (& docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{if .State.Running}}running{{else}}stopped{{end}}{{end}}' $containerId[0] 2>$null)
            if ((($status -join '').Trim()) -in @('healthy', 'running')) { return }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "$Service did not become healthy within $TimeoutSeconds seconds."
}

Import-DotEnv -Path $EnvFile
if ([string]::IsNullOrWhiteSpace($env:DD_POSTGRES_PASSWORD)) { throw 'DD_POSTGRES_PASSWORD is missing.' }
if ([string]::IsNullOrWhiteSpace($env:DD_REDIS_PASSWORD)) { throw 'DD_REDIS_PASSWORD is missing.' }

$goCommand = Get-Command go.exe -ErrorAction SilentlyContinue
if ($null -ne $goCommand) {
    $GoExe = $goCommand.Source
} else {
    $GoExe = 'C:\Program Files\Go\bin\go.exe'
    if (-not (Test-Path -LiteralPath $GoExe)) {
        throw 'Go was not found in PATH or C:\Program Files\Go\bin\go.exe.'
    }
}

$postgresWasRunning = Test-ComposeServiceRunning -Service 'postgres'
$redisWasRunning = Test-ComposeServiceRunning -Service 'redis'

try {
    & docker compose --env-file $EnvFile -f $ComposeFile up -d postgres redis
    if ($LASTEXITCODE -ne 0) { throw 'Unable to start PostgreSQL/Redis.' }
    Wait-ComposeHealthy -Service 'postgres'
    Wait-ComposeHealthy -Service 'redis'

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'invoke-dev-migrate.ps1') up
    if ($LASTEXITCODE -ne 0) { throw 'Database migration failed.' }

    $env:DD_RUN_P4_LOAD = '1'
    $env:DD_MESSAGING_TEST_DATABASE_URL = "postgres://dd:$($env:DD_POSTGRES_PASSWORD)@127.0.0.1:15432/dd?sslmode=disable"
    $escapedRedisPassword = [System.Uri]::EscapeDataString($env:DD_REDIS_PASSWORD)
    $env:DD_REALTIME_TEST_REDIS_URL = "redis://:$escapedRedisPassword@127.0.0.1:16379/0"

    Write-Host ''
    Write-Host '[1/3] PostgreSQL message throughput baseline (>= 100 msg/s)'
    Push-Location $ServerDir
    try {
        & $GoExe test ./internal/messaging -run '^TestMessagingLoadAtLeast100MessagesPerSecond$' -count=1 -v
        if ($LASTEXITCODE -ne 0) { throw 'Messaging throughput baseline failed.' }

        Write-Host ''
        Write-Host '[2/3] 200 authenticated realtime WebSocket connections'
        & $GoExe test ./internal/httpapi -run '^TestFormalRealtimeLoad200AuthenticatedConnections$' -count=1 -v
        if ($LASTEXITCODE -ne 0) { throw 'Realtime connection baseline failed.' }

        Write-Host ''
        Write-Host '[3/3] Redis cross-node delivery + forced Pub/Sub reconnect'
        & $GoExe test ./internal/realtimebus -run '^TestRedisBusCrossNodeDeliveryAndPubSubReconnect$' -count=1 -v
        if ($LASTEXITCODE -ne 0) { throw 'Redis realtime recovery baseline failed.' }
    }
    finally {
        Pop-Location
    }

    Write-Host ''
    Write-Host 'P4 reliability/load baseline: PASS' -ForegroundColor Green
}
finally {
    Remove-Item Env:DD_RUN_P4_LOAD -ErrorAction SilentlyContinue
    Remove-Item Env:DD_MESSAGING_TEST_DATABASE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:DD_REALTIME_TEST_REDIS_URL -ErrorAction SilentlyContinue

    if (-not $postgresWasRunning) {
        & docker compose --env-file $EnvFile -f $ComposeFile stop postgres *> $null
    }
    if (-not $redisWasRunning) {
        & docker compose --env-file $EnvFile -f $ComposeFile stop redis *> $null
    }
}
