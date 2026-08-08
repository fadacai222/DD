$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$Spec = Join-Path $Root 'server\openapi\openapi.json'
$RedoclyVersion = '2.45.0'

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw 'Node.js is required to lint OpenAPI.'
}
if (-not (Get-Command npx -ErrorAction SilentlyContinue)) {
    throw 'npx is required to lint OpenAPI.'
}

& npx -y "@redocly/cli@$RedoclyVersion" lint $Spec --extends=recommended-strict
if ($LASTEXITCODE -ne 0) {
    throw 'OpenAPI lint failed.'
}

Write-Host 'OPENAPI_LINT_PASSED=true'
