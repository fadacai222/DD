param(
    [ValidateSet('up', 'down', 'status')]
    [string]$Action = 'up'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$EnvFile = Join-Path $Root 'infra\dev\.env'
$GoExe = 'C:\Program Files\Go\bin\go.exe'

if (-not (Test-Path -LiteralPath $EnvFile)) {
    throw 'Missing infra\dev\.env. Run .\scripts\init-dev-env.ps1 first.'
}
if (-not (Test-Path -LiteralPath $GoExe)) {
    throw "Go not found: $GoExe"
}

$values = @{}
foreach ($line in [System.IO.File]::ReadAllLines($EnvFile)) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
    $separator = $line.IndexOf('=')
    if ($separator -le 0) { continue }
    $values[$line.Substring(0, $separator)] = $line.Substring($separator + 1)
}

foreach ($required in @('DD_POSTGRES_DB', 'DD_POSTGRES_USER', 'DD_POSTGRES_PASSWORD')) {
    if (-not $values.ContainsKey($required) -or [string]::IsNullOrWhiteSpace($values[$required])) {
        throw "Missing $required in infra\dev\.env"
    }
}

$user = [Uri]::EscapeDataString($values['DD_POSTGRES_USER'])
$password = [Uri]::EscapeDataString($values['DD_POSTGRES_PASSWORD'])
$database = [Uri]::EscapeDataString($values['DD_POSTGRES_DB'])
$previousDatabaseUrl = $env:DATABASE_URL
$env:DATABASE_URL = "postgres://$user`:$password@127.0.0.1:15432/${database}?sslmode=disable"

Push-Location (Join-Path $Root 'server')
try {
    & $GoExe run ./cmd/migrate $Action
    if ($LASTEXITCODE -ne 0) {
        throw "Migration action '$Action' failed."
    }
} finally {
    Pop-Location
    if ($null -eq $previousDatabaseUrl) {
        Remove-Item Env:DATABASE_URL -ErrorAction SilentlyContinue
    } else {
        $env:DATABASE_URL = $previousDatabaseUrl
    }
}
