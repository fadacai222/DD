param(
    [switch]$WithInfra,
    [switch]$WithE2EECrossCompile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$GoExe = 'C:\Program Files\Go\bin\go.exe'
$DartExe = 'C:\dev\flutter\bin\cache\dart-sdk\bin\dart.exe'
$FlutterExe = 'C:\dev\flutter\bin\flutter.bat'

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    Write-Host ''
    Write-Host "=== $Name ==="
    & $Action
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE."
    }
}

if (-not (Test-Path -LiteralPath $GoExe)) { throw "Go not found: $GoExe" }
if (-not (Test-Path -LiteralPath $DartExe)) { throw "Dart not found: $DartExe" }
if (-not (Test-Path -LiteralPath $FlutterExe)) { throw "Flutter not found: $FlutterExe" }

Invoke-Step 'Go tests and vet' {
    Push-Location (Join-Path $Root 'server')
    try {
        & $GoExe test ./...
        if ($LASTEXITCODE -ne 0) { return }
        & $GoExe vet ./...
    } finally { Pop-Location }
}

Invoke-Step 'OpenAPI strict lint' {
    & (Join-Path $PSScriptRoot 'lint-openapi.ps1')
}

Invoke-Step 'Realtime v1 Go/Dart contract' {
    & (Join-Path $PSScriptRoot 'test-realtime-protocol.ps1')
}

Invoke-Step 'E2EE native PoC' {
    if ($WithE2EECrossCompile) {
        & (Join-Path $PSScriptRoot 'test-e2ee-poc.ps1')
    } else {
        & (Join-Path $PSScriptRoot 'test-e2ee-poc.ps1') -SkipCrossCompile
    }
}

Invoke-Step 'Admin typecheck and production build' {
    Push-Location (Join-Path $Root 'admin')
    try {
        & npm ci --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { return }
        & npm run typecheck
        if ($LASTEXITCODE -ne 0) { return }
        & npm run build
    } finally { Pop-Location }
}

Invoke-Step 'Flutter analyze and tests' {
    Push-Location (Join-Path $Root 'clients\app')
    try {
        & $DartExe analyze
        if ($LASTEXITCODE -ne 0) { return }
        & $FlutterExe test
    } finally { Pop-Location }
}

$dummyEnvironment = @{
    DD_POSTGRES_PASSWORD = '0123456789abcdef0123456789abcdef'
    DD_REDIS_PASSWORD = '0123456789abcdef0123456789abcdef'
    DD_MINIO_ROOT_PASSWORD = '0123456789abcdef0123456789abcdef'
    DD_LIVEKIT_API_KEY = 'dddev_0123456789abcdef'
    DD_LIVEKIT_API_SECRET = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
}
$previousEnvironment = @{}
foreach ($key in $dummyEnvironment.Keys) {
    $previousEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
    [Environment]::SetEnvironmentVariable($key, $dummyEnvironment[$key], 'Process')
}
try {
    Invoke-Step 'Development Compose config' {
        & docker compose -f (Join-Path $Root 'infra\dev\compose.yml') config --quiet
    }
} finally {
    foreach ($key in $dummyEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($key, $previousEnvironment[$key], 'Process')
    }
}

if ($WithInfra) {
    $envFile = Join-Path $Root 'infra\dev\.env'
    if (-not (Test-Path -LiteralPath $envFile)) {
        & (Join-Path $PSScriptRoot 'init-dev-env.ps1')
    }
    try {
        Invoke-Step 'Start development infrastructure' {
            & (Join-Path $PSScriptRoot 'start-dev-infra.ps1')
        }
        Invoke-Step 'Development infrastructure health' {
            & (Join-Path $PSScriptRoot 'test-dev-infra.ps1')
        }
        Invoke-Step 'Migration round trip' {
            & (Join-Path $PSScriptRoot 'test-migrations.ps1')
        }
    } finally {
        & (Join-Path $PSScriptRoot 'stop-dev-infra.ps1')
    }
}

Write-Host ''
Write-Host 'FOUNDATION_TEST_PASSED=true'
