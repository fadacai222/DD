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

function Get-FreeSubstDrive {
    $Used = @{}
    foreach ($Line in (& subst.exe)) {
        if ($Line -match '^([A-Z]:)') {
            $Used[$Matches[1]] = $true
        }
    }

    foreach ($Drive in @('O:', 'P:', 'Q:', 'R:', 'S:', 'T:')) {
        if (-not $Used.ContainsKey($Drive) -and -not (Test-Path "$Drive\")) {
            return $Drive
        }
    }
    throw 'No free drive letter is available for the ASCII path test workaround.'
}

function Get-FreeTcpPort {
    for ($Attempt = 0; $Attempt -lt 200; $Attempt++) {
        $Candidate = Get-Random -Minimum 10000 -Maximum 65536
        $Listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Candidate)
        try {
            $Listener.Start()
            return $Candidate
        }
        catch [System.Net.Sockets.SocketException] {
            continue
        }
        finally {
            $Listener.Stop()
        }
    }

    throw 'Unable to allocate a free five-digit TCP port for smoke testing.'
}

$Port = Get-FreeTcpPort

foreach ($Tool in @($GoExe, $GoFmtExe, $FlutterExe, $DartExe)) {
    if (-not (Test-Path -LiteralPath $Tool)) {
        throw "Required tool not found: $Tool"
    }
}

$DeveloperMode = Get-ItemPropertyValue `
    -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' `
    -Name 'AllowDevelopmentWithoutDevLicense' `
    -ErrorAction SilentlyContinue
if ($DeveloperMode -ne 1) {
    throw 'Windows Developer Mode is required for Flutter plugins. Run .\scripts\enable-windows-developer-mode.ps1 first.'
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

$SubstDrive = Get-FreeSubstDrive
& subst.exe $SubstDrive $Root
if ($LASTEXITCODE -ne 0) {
    throw "Failed to map $SubstDrive to the project root for Dart/Flutter checks."
}
try {
    $MappedRealtimePath = "$SubstDrive\clients\realtime_poc"
    $MappedAppPath = "$SubstDrive\clients\app"

    Write-Host "[2/5] Realtime package checks (ASCII path: $MappedRealtimePath)"
    Invoke-Checked $DartExe @('pub', 'get') $MappedRealtimePath 'Realtime pub get failed.'
    Invoke-Checked $DartExe @('format', '--output=none', '--set-exit-if-changed', 'lib', 'test', 'tool') $MappedRealtimePath 'Realtime format check failed.'
    Invoke-Checked $DartExe @('analyze', '--fatal-infos') $MappedRealtimePath 'Realtime analyze failed.'
    Invoke-Checked $DartExe @('test', '-r', 'expanded') $MappedRealtimePath 'Realtime tests failed.'

    Write-Host "[3/5] Flutter app checks (ASCII path: $MappedAppPath)"
    Invoke-Checked $FlutterExe @('pub', 'get') $MappedAppPath 'Flutter pub get failed.'
    Invoke-Checked $DartExe @('format', '--output=none', '--set-exit-if-changed', 'lib', 'test') $MappedAppPath 'App format check failed.'
    Invoke-Checked $DartExe @('analyze', '--fatal-infos') $MappedAppPath 'App analyze failed.'
    Invoke-Checked $FlutterExe @('test', '--reporter', 'expanded') $MappedAppPath 'Flutter tests failed.'
}
finally {
    Set-Location 'C:\'
    & subst.exe $SubstDrive /D | Out-Null
}

Write-Host '[4/5] Live REST and WebSocket smoke test'
Write-Host "Temporary smoke-test port: $Port"
$Existing = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($Existing) {
    throw "Dynamically selected test port $Port became occupied before startup. Re-run the test."
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
