param(
    [string]$LanIP,
    [switch]$SkipClientBuild,
    [switch]$SkipWeb
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$ServerDir = Join-Path $Root 'server'
$ComposeFile = Join-Path $Root 'infra\dev\compose.yml'
$EnvFile = Join-Path $Root 'infra\dev\.env'
$InitEnvScript = Join-Path $PSScriptRoot 'init-dev-env.ps1'
$BuildClientScript = Join-Path $PSScriptRoot 'build-client.ps1'
$StartWebScript = Join-Path $PSScriptRoot 'start-web-client.ps1'
$StopWebScript = Join-Path $PSScriptRoot 'stop-web-client.ps1'
$StopCallCrossPlatformScript = Join-Path $PSScriptRoot 'stop-call-poc-crossplatform.ps1'
$StopCallScript = Join-Path $PSScriptRoot 'stop-call-poc.ps1'
$StopRealtimePocScript = Join-Path $PSScriptRoot 'stop-poc.ps1'
$CallComposeFile = Join-Path $Root 'compose.call-poc.yml'
$RealtimePocComposeFile = Join-Path $Root 'compose.poc.yml'
$FirewallScript = Join-Path $PSScriptRoot 'configure-auth-dev-firewall.ps1'
$StateDir = Join-Path $Root '.data'
$StateFile = Join-Path $StateDir 'auth-dev.json'
$CallStateFile = Join-Path $StateDir 'call-poc-crossplatform.json'
$LanCallStateFile = Join-Path $StateDir 'call-poc-lan.json'
$WebStateFile = Join-Path $StateDir 'web-client.json'
$ApiExe = Join-Path $StateDir 'dd-auth-dev-api.exe'
$ApiOut = Join-Path $StateDir 'dd-auth-dev-api.out.log'
$ApiErr = Join-Path $StateDir 'dd-auth-dev-api.err.log'
$WorkerExe = Join-Path $StateDir 'dd-auth-dev-worker.exe'
$WorkerOut = Join-Path $StateDir 'dd-auth-dev-worker.out.log'
$WorkerErr = Join-Path $StateDir 'dd-auth-dev-worker.err.log'

function Test-PrivateIPv4 {
    param([Parameter(Mandatory = $true)][string]$Address)
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return $false }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $bytes = $parsed.GetAddressBytes()
    if ($bytes[0] -eq 10) { return $true }
    if ($bytes[0] -eq 192 -and $bytes[1] -eq 168) { return $true }
    if ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) { return $true }
    return $false
}

function Get-PreferredLanIP {
    $candidates = @()
    foreach ($configuration in Get-NetIPConfiguration) {
        if ($null -eq $configuration.IPv4DefaultGateway) { continue }
        if ($null -eq $configuration.NetAdapter -or $configuration.NetAdapter.Status -ne 'Up') { continue }
        foreach ($address in @($configuration.IPv4Address)) {
            if ($null -eq $address) { continue }
            $ip = [string]$address.IPAddress
            if (-not (Test-PrivateIPv4 -Address $ip)) { continue }
            $metricInfo = Get-NetIPInterface -InterfaceIndex $configuration.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            $metric = if ($null -eq $metricInfo) { 9999 } else { [int]$metricInfo.InterfaceMetric }
            $candidates += [pscustomobject]@{ IP = $ip; InterfaceAlias = $configuration.InterfaceAlias; Metric = $metric }
        }
    }
    $preferred = $candidates | Sort-Object Metric, InterfaceAlias | Select-Object -First 1
    if ($null -eq $preferred) { throw 'No active private IPv4 interface with a default gateway was found. Supply -LanIP explicitly.' }
    return $preferred
}

function Assert-LocalLanIP {
    param([Parameter(Mandatory = $true)][string]$Address)
    if (-not (Test-PrivateIPv4 -Address $Address)) { throw "LAN IP must be private IPv4, got: $Address" }
    if ($null -eq (Get-NetIPAddress -AddressFamily IPv4 -IPAddress $Address -ErrorAction SilentlyContinue)) {
        throw "LAN IP $Address is not assigned to this computer."
    }
}

function Import-DotEnv {
    param([Parameter(Mandatory = $true)][string]$Path)
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
        $separator = $trimmed.IndexOf('=')
        if ($separator -le 0) { continue }
        $name = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1)
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
}

function New-HexSecret {
    param([int]$Bytes = 32)
    $buffer = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($buffer)
    }
    finally {
        $rng.Dispose()
    }
    return -join ($buffer | ForEach-Object { $_.ToString('x2') })
}

function Ensure-AuthTokenSecret {
    if (-not [string]::IsNullOrWhiteSpace($env:AUTH_TOKEN_SECRET)) { return }
    $secret = New-HexSecret 32
    Add-Content -LiteralPath $EnvFile -Value "AUTH_TOKEN_SECRET=$secret" -Encoding UTF8
    $env:AUTH_TOKEN_SECRET = $secret
    Write-Host 'Added missing AUTH_TOKEN_SECRET to infra/dev/.env.'
}

function Test-ComposeServiceRunning {
    param([Parameter(Mandatory = $true)][string]$Service)
    $id = (& docker compose --env-file $EnvFile -f $ComposeFile ps -q $Service 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($id)) { return $false }
    return ((& docker inspect -f '{{.State.Running}}' $id 2>$null) -join '').Trim() -eq 'true'
}

function Test-ComposeServiceRunningByFile {
    param(
        [Parameter(Mandatory = $true)][string]$ComposePath,
        [Parameter(Mandatory = $true)][string]$Service
    )
    if (-not (Test-Path -LiteralPath $ComposePath)) { return $false }
    $id = (& docker compose -f $ComposePath ps -q $Service 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($id)) { return $false }
    return ((& docker inspect -f '{{.State.Running}}' $id 2>$null) -join '').Trim() -eq 'true'
}

function Wait-ComposeHealthy {
    param([Parameter(Mandatory = $true)][string]$Service)
    foreach ($attempt in 1..40) {
        $id = (& docker compose --env-file $EnvFile -f $ComposeFile ps -q $Service 2>$null | Select-Object -First 1)
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            $health = ((& docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' $id 2>$null) -join '').Trim()
            if ($health -eq 'healthy' -or $health -eq 'running') { return }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Timed out waiting for Docker service: $Service"
}

function Wait-HttpOK {
    param([Parameter(Mandatory = $true)][string]$Url)
    foreach ($attempt in 1..60) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 2
            if ($response.StatusCode -eq 200) { return }
        }
        catch {
            Start-Sleep -Milliseconds 250
        }
    }
    throw "Timed out waiting for $Url"
}

if (Test-Path -LiteralPath $StateFile) {
    throw 'P2 Auth dev environment already has an active state file. Stop it first with stop-auth-dev.ps1.'
}

& docker info *> $null
if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop is not running.' }
$goCommand = Get-Command go.exe -ErrorAction SilentlyContinue
if ($null -ne $goCommand) {
    $GoExe = $goCommand.Source
} else {
    $GoExe = 'C:\Program Files\Go\bin\go.exe'
    if (-not (Test-Path -LiteralPath $GoExe)) {
        throw 'Go was not found in PATH or C:\Program Files\Go\bin\go.exe.'
    }
}

if ([string]::IsNullOrWhiteSpace($LanIP)) {
    $selected = Get-PreferredLanIP
    $LanIP = $selected.IP
    Write-Host "Detected LAN interface: $($selected.InterfaceAlias) -> $LanIP"
} else {
    $LanIP = $LanIP.Trim()
}
Assert-LocalLanIP -Address $LanIP

if (Test-Path -LiteralPath $CallStateFile) {
    Write-Host 'Stopping the previous cross-platform Call PoC environment...'
    & $StopCallCrossPlatformScript
    if ($LASTEXITCODE -ne 0) { throw 'Unable to stop the existing cross-platform Call PoC environment.' }
}

if ((Test-Path -LiteralPath $LanCallStateFile) -or (Test-ComposeServiceRunningByFile -ComposePath $CallComposeFile -Service 'realtime-api')) {
    Write-Host 'Stopping the project Call PoC environment to release port 18473...'
    & $StopCallScript
    if ($LASTEXITCODE -ne 0) { throw 'Unable to stop the existing Call PoC environment.' }
}

if (Test-ComposeServiceRunningByFile -ComposePath $RealtimePocComposeFile -Service 'realtime-api') {
    Write-Host 'Stopping the project Realtime PoC environment to release port 18473...'
    & $StopRealtimePocScript
    if ($LASTEXITCODE -ne 0) { throw 'Unable to stop the existing Realtime PoC environment.' }
}

$portOwner = Get-NetTCPConnection -LocalPort 18473 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -ne $portOwner) {
    $processName = (Get-Process -Id $portOwner.OwningProcess -ErrorAction SilentlyContinue).ProcessName
    $ownerLabel = if ([string]::IsNullOrWhiteSpace($processName)) { "PID $($portOwner.OwningProcess)" } else { "$processName (PID $($portOwner.OwningProcess))" }
    throw "TCP 18473 is still in use by $ownerLabel. It is not a recognized DD PoC service, so Auth dev refused to kill it automatically."
}

New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
if (-not (Test-Path -LiteralPath $EnvFile)) {
    & $InitEnvScript
    if ($LASTEXITCODE -ne 0) { throw 'Failed to initialize infra/dev/.env.' }
}
Import-DotEnv -Path $EnvFile
Ensure-AuthTokenSecret

if ([string]::IsNullOrWhiteSpace($env:DD_POSTGRES_PASSWORD)) { throw 'DD_POSTGRES_PASSWORD is missing from infra/dev/.env.' }
if ([string]::IsNullOrWhiteSpace($env:DD_REDIS_PASSWORD)) { throw 'DD_REDIS_PASSWORD is missing from infra/dev/.env.' }
if ([string]::IsNullOrWhiteSpace($env:EMAIL_CODE_PEPPER)) { throw 'EMAIL_CODE_PEPPER is missing from infra/dev/.env.' }

$postgresWasRunning = Test-ComposeServiceRunning -Service 'postgres'
$mailpitWasRunning = Test-ComposeServiceRunning -Service 'mailpit'
$redisWasRunning = Test-ComposeServiceRunning -Service 'redis'
$webWasRunning = Test-Path -LiteralPath $WebStateFile
$apiProcess = $null
$workerProcess = $null
$startedWeb = $false
$firewallReady = $false

try {
    & $FirewallScript -LanIP $LanIP
    if ($LASTEXITCODE -ne 0) { throw 'Unable to configure Auth LAN firewall.' }
    $firewallReady = $true

    & docker compose --env-file $EnvFile -f $ComposeFile up -d postgres mailpit redis
    if ($LASTEXITCODE -ne 0) { throw 'Unable to start PostgreSQL/Mailpit/Redis.' }
    Wait-ComposeHealthy -Service 'postgres'
    Wait-ComposeHealthy -Service 'mailpit'
    Wait-ComposeHealthy -Service 'redis'

    $env:IM_ENV = 'development'
    $env:IM_PORT = '18473'
    $env:IM_INSTANCE_NAME = 'DD'
    $env:IM_PUBLIC_BASE_URL = ''
    $env:IM_REGISTRATION_MODE = 'open'
    $env:IM_ALLOWED_HTTP_ORIGINS = "http://localhost:*,http://127.0.0.1:*,http://$LanIP`:*"
    $env:IM_ALLOWED_ORIGINS = "localhost:*,127.0.0.1:*,10.0.2.2:*,$LanIP`:*"
    $env:DATABASE_URL = "postgres://dd:$($env:DD_POSTGRES_PASSWORD)@127.0.0.1:15432/dd?sslmode=disable"
    $escapedRedisPassword = [System.Uri]::EscapeDataString($env:DD_REDIS_PASSWORD)
    $env:REDIS_URL = "redis://:$escapedRedisPassword@127.0.0.1:16379/0"
    $env:SMTP_HOST = '127.0.0.1'
    $env:SMTP_PORT = '11025'
    $env:SMTP_FROM = 'noreply@dd.local'
    $env:SMTP_USERNAME = ''
    $env:SMTP_PASSWORD = ''
    $env:SMTP_REQUIRE_TLS = 'false'
    $env:LIVEKIT_URL = ''
    $env:LIVEKIT_API_KEY = ''
    $env:LIVEKIT_API_SECRET = ''

    Push-Location $ServerDir
    try {
        & $GoExe run ./cmd/migrate up
        if ($LASTEXITCODE -ne 0) { throw 'Database migration failed.' }
        & $GoExe build -trimpath -o $ApiExe ./cmd/api
        if ($LASTEXITCODE -ne 0) { throw 'Auth API build failed.' }
        & $GoExe build -trimpath -o $WorkerExe ./cmd/worker
        if ($LASTEXITCODE -ne 0) { throw 'Messaging Worker build failed.' }
    }
    finally {
        Pop-Location
    }

    Remove-Item -LiteralPath $ApiOut, $ApiErr, $WorkerOut, $WorkerErr -Force -ErrorAction SilentlyContinue
    $apiProcess = Start-Process `
        -FilePath $ApiExe `
        -WorkingDirectory $ServerDir `
        -RedirectStandardOutput $ApiOut `
        -RedirectStandardError $ApiErr `
        -WindowStyle Hidden `
        -PassThru
    Wait-HttpOK 'http://127.0.0.1:18473/api/v1/system/live'

    $workerProcess = Start-Process `
        -FilePath $WorkerExe `
        -WorkingDirectory $ServerDir `
        -RedirectStandardOutput $WorkerOut `
        -RedirectStandardError $WorkerErr `
        -WindowStyle Hidden `
        -PassThru
    Start-Sleep -Milliseconds 500
    if ($workerProcess.HasExited) {
        throw "Messaging Worker exited during startup. See $WorkerErr"
    }

    if (-not $SkipClientBuild) {
        & $BuildClientScript -Target all
        if ($LASTEXITCODE -ne 0) { throw 'Client build failed.' }
    }

    if (-not $SkipWeb -and -not $webWasRunning) {
        & $StartWebScript -SkipBuild
        if ($LASTEXITCODE -ne 0) { throw 'Web client failed to start.' }
        $startedWeb = $true
    }

    $webUrl = $null
    if (Test-Path -LiteralPath $WebStateFile) {
        $webState = Get-Content -LiteralPath $WebStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $webUrl = "http://127.0.0.1:$([int]$webState.port)"
    }

    [pscustomobject]@{
        startedAt = (Get-Date).ToString('o')
        lanIP = $LanIP
        apiPid = $apiProcess.Id
        workerPid = $workerProcess.Id
        postgresStartedByScript = -not $postgresWasRunning
        mailpitStartedByScript = -not $mailpitWasRunning
        redisStartedByScript = -not $redisWasRunning
        webStartedByScript = $startedWeb
        webUrl = $webUrl
    } | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8

    Write-Host ''
    Write-Host 'P2 Auth dev environment is ready.'
    Write-Host '  Windows API: http://127.0.0.1:18473'
    Write-Host "  Android API: http://$LanIP`:18473"
    Write-Host '  Mailpit:     http://127.0.0.1:18025'
    Write-Host '  Redis:       127.0.0.1:16379'
    if ($null -ne $webUrl) { Write-Host "  Web:         $webUrl" }
    Write-Host "  API PID:     $($apiProcess.Id)"
    Write-Host "  Worker PID:  $($workerProcess.Id)"
    Write-Host ''
    Write-Host 'Open DD -> 账号注册 / 登录. Use a fresh email address for each registration test.'
    Write-Host 'Stop: powershell -ExecutionPolicy Bypass -File .\scripts\stop-auth-dev.ps1'
}
catch {
    $originalError = $_
    if ($null -ne $apiProcess -and -not $apiProcess.HasExited) {
        Stop-Process -Id $apiProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $workerProcess -and -not $workerProcess.HasExited) {
        Stop-Process -Id $workerProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($startedWeb) {
        & $StopWebScript *> $null
    }
    if (-not $postgresWasRunning) {
        & docker compose --env-file $EnvFile -f $ComposeFile stop postgres *> $null
    }
    if (-not $mailpitWasRunning) {
        & docker compose --env-file $EnvFile -f $ComposeFile stop mailpit *> $null
    }
    if (-not $redisWasRunning) {
        & docker compose --env-file $EnvFile -f $ComposeFile stop redis *> $null
    }
    if ($firewallReady) {
        & $FirewallScript -LanIP $LanIP -Remove *> $null
    }
    Remove-Item -LiteralPath $StateFile, $ApiExe, $WorkerExe, $ApiOut, $ApiErr, $WorkerOut, $WorkerErr -Force -ErrorAction SilentlyContinue
    throw $originalError
}
