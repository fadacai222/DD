param(
    [switch]$PurgeData
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$DevDir = Join-Path $Root 'infra\dev'
$ComposeFile = Join-Path $DevDir 'compose.yml'
$EnvFile = Join-Path $DevDir '.env'

if (-not (Test-Path -LiteralPath $EnvFile)) {
    Write-Host 'No infra\dev\.env found; nothing to stop.'
    exit 0
}

Push-Location $DevDir
try {
    $arguments = @('compose', '--env-file', $EnvFile, '-f', $ComposeFile, 'down', '--remove-orphans')
    if ($PurgeData) {
        $arguments += '--volumes'
    }
    & docker @arguments
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to stop development infrastructure.'
    }
} finally {
    Pop-Location
}

if ($PurgeData) {
    Write-Host 'Development infrastructure stopped and local volumes removed.'
} else {
    Write-Host 'Development infrastructure stopped. Local volumes were preserved.'
}
