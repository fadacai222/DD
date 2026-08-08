$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$StateFile = Join-Path $Root '.data\call-poc-crossplatform.json'
$StopLanScript = Join-Path $PSScriptRoot 'stop-call-poc-lan.ps1'
$StopWebScript = Join-Path $PSScriptRoot 'stop-web-client.ps1'

if (-not (Test-Path -LiteralPath $StateFile)) {
    Write-Host 'Cross-platform Call PoC is not running (no state file found).'
    exit 0
}

try {
    $State = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    throw 'Cross-platform Call PoC state file is invalid. Refusing blind cleanup.'
}

$errors = @()

if ([bool]$State.startedWeb) {
    try {
        & $StopWebScript
        if ($LASTEXITCODE -ne 0) { throw 'Web stop script returned a non-zero exit code.' }
    }
    catch {
        $errors += "Web cleanup failed: $($_.Exception.Message)"
    }
}
else {
    Write-Host 'Web client was reused; leaving it running.'
}

if ([bool]$State.startedLan) {
    try {
        & $StopLanScript
        if ($LASTEXITCODE -ne 0) { throw 'LAN stop script returned a non-zero exit code.' }
    }
    catch {
        $errors += "LAN cleanup failed: $($_.Exception.Message)"
    }
}
else {
    Write-Host 'LAN Call PoC was reused; leaving it running.'
}

if ($errors.Count -gt 0) {
    throw ($errors -join "`n")
}

Remove-Item -LiteralPath $StateFile -Force
Write-Host 'Cross-platform Call PoC stopped. Resources that existed before startup were preserved.'
