$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$GoExe = 'C:\Program Files\Go\bin\go.exe'
$DartExe = 'C:\dev\flutter\bin\cache\dart-sdk\bin\dart.exe'

if (-not (Test-Path -LiteralPath $GoExe)) {
    throw "Go not found: $GoExe"
}
if (-not (Test-Path -LiteralPath $DartExe)) {
    throw "Dart not found: $DartExe"
}

Push-Location (Join-Path $Root 'server')
try {
    & $GoExe test ./internal/realtimev1
    if ($LASTEXITCODE -ne 0) {
        throw 'Go realtime v1 contract tests failed.'
    }
} finally {
    Pop-Location
}

Push-Location (Join-Path $Root 'packages\realtime_protocol')
try {
    & $DartExe pub get
    if ($LASTEXITCODE -ne 0) {
        throw 'Dart dependency resolution failed.'
    }
    & $DartExe test
    if ($LASTEXITCODE -ne 0) {
        throw 'Dart realtime v1 contract tests failed.'
    }
} finally {
    Pop-Location
}

Write-Host 'REALTIME_PROTOCOL_CONTRACT_TEST_PASSED=true'
