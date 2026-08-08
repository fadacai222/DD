param(
    [int]$Count = 3
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Count -lt 1 -or $Count -gt 20) {
    throw 'Count must be between 1 and 20.'
}

$Root = Split-Path -Parent $PSScriptRoot
$GoExe = 'C:\Program Files\Go\bin\go.exe'
if (-not (Test-Path -LiteralPath $GoExe)) {
    throw "Go not found: $GoExe"
}

Push-Location (Join-Path $Root 'server')
try {
    & $GoExe test ./internal/auth/password -run '^$' -bench '^BenchmarkDefaultHash$' -benchtime "${Count}x" -benchmem
    if ($LASTEXITCODE -ne 0) {
        throw 'Argon2id benchmark failed.'
    }
} finally {
    Pop-Location
}
