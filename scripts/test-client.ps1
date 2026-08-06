$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$ServerPath = Join-Path $Root 'server'
$RealtimePath = Join-Path $Root 'clients\realtime_poc'
$AppPath = Join-Path $Root 'clients\app'
$GoExe = 'C:\Program Files\Go\bin\go.exe'
$GoFmtExe = 'C:\Program Files\Go\bin\gofmt.exe'
$FlutterExe = 'C:\dev\flutter\bin\flutter.bat'
$DartExe = 'C:\dev\flutter\bin\cache\dart-sdk\bin\dart.exe'
$Port = 18473

foreach ($Tool in @($GoExe, $GoFmtExe, $FlutterExe, $DartExe)) {
    if (-not (Test-Path -LiteralPath $Tool)) {
        throw "Required tool not found: $Tool"
    }
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )

    Push-Location $WorkingDirectory
    try {
        & $FilePath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw $FailureMessage
        }
    }
    finally {
        Pop-Location
    }
}

Write-Host '[1/5] Go format, vet, and tests'
Push-Location $ServerPath
try {
    $Unformatted = & $GoFmtExe -l .
    if ($LASTEXITCODE -ne 0) { throw 'gofmt failed.' }
    if ($Unformatted) {
        throw "Go files require formatting:`n$($Unformatted -join "`n")"
    }
}
finally {
    Pop-Location
}
Invoke-Checked $GoExe @('vet', './...') $ServerPath 'go vet failed.'
Invoke-Checked $GoExe @('test', './...') $ServerPath 'Go tests failed.'

Write-Host '[2/5] Realtime package checks'
Invoke-Checked $DartExe @('pub', 'get') $RealtimePath 'Realtime pub get failed.'
Invoke-Checked $DartExe @('format', '--output=none', '--set-exit-if-changed', 'lib', 'test', 'tool') $RealtimePath 'Realtime format check failed.'
Invoke-Checked $DartExe @('analyze', '--fatal-infos') $RealtimePath 'Realtime analyze failed.'
Invoke-Checked $DartExe @('test', '-r', 'expanded') $RealtimePath 'Realtime tests failed.'

Write-Host '[3/5] Flutter app checks'
Invoke-Checked $FlutterExe @('pub', 'get') $AppPath 'Flutter pub get failed.'
Invoke-Checked $DartExe @('format', '--output=none', '--set-exit-if-changed', 'lib', 'test') $AppPath 'App format check failed.'
Invoke-Checked $DartExe @('analyze', '--fatal-infos') $AppPath 'App analyze failed.'
Invoke-Checked $FlutterExe @('test', '--reporter', 'expanded') $AppPath 'Flutter tests failed.'

Write-Host '[4/5] Live REST and WebSocket smoke test'
$Existing = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($Existing) {
    throw "Port $Port is already in use. Stop the existing process first."
}

$Binary = Join-Path $env:TEMP ("openimx-realtime-test-$PID.exe")
$ServerProcess = $null
try {
    Invoke-Checked $GoExe @('build', '-o', $Binary, '.\cmd\api') $ServerPath 'Go server build failed.'
    $env:IM_PORT = [string]$Port
    $ServerProcess = Start-Process -FilePath $Binary -PassThru -WindowStyle Hidden

    $Ready = $false
    for ($Attempt = 0; $Attempt -lt 30; $Attempt++) {
        try {
            $Health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 1
            if ($Health.status -eq 'ok') {
                $Ready = $true
                break
            }
        }
        catch {
            Start-Sleep -Milliseconds 200
        }
    }
    if (-not $Ready) {
        throw 'Temporary Go server did not become ready.'
    }

    Invoke-Checked $DartExe @('run', '.\tool\live_smoke.dart', "http://127.0.0.1:$Port") $RealtimePath 'Live smoke test failed.'
}
finally {
    if ($ServerProcess -and -not $ServerProcess.HasExited) {
        Stop-Process -Id $ServerProcess.Id -Force -ErrorAction SilentlyContinue
        $ServerProcess.WaitForExit()
    }
    Remove-Item -LiteralPath $Binary -Force -ErrorAction SilentlyContinue
    Remove-Item Env:IM_PORT -ErrorAction SilentlyContinue
}

Write-Host '[5/5] Residual process and port check'
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
    throw "Port $Port is still occupied after cleanup."
}

Write-Host 'All client and realtime checks passed.'
