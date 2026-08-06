$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$ServerPath = Join-Path $Root 'server'
$RealtimePath = Join-Path $Root 'clients\realtime_poc'
$GoExe = 'C:\Program Files\Go\bin\go.exe'
$DartExe = 'C:\dev\flutter\bin\cache\dart-sdk\bin\dart.exe'
$Port = 18473

if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
    throw "Port $Port already has a listening process."
}

$Binary = Join-Path $env:TEMP ("openimx-reconnect-$PID.exe")
$StdoutPath = Join-Path $env:TEMP ("openimx-reconnect-$PID.out")
$StderrPath = Join-Path $env:TEMP ("openimx-reconnect-$PID.err")
$FirstServer = $null
$SecondServer = $null
$Client = $null

function Start-TestServer {
    $env:IM_PORT = [string]$Port
    return Start-Process -FilePath $Binary -PassThru -WindowStyle Hidden
}

function Wait-ServerReady {
    for ($Attempt = 0; $Attempt -lt 30; $Attempt++) {
        try {
            $Health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 1
            if ($Health.status -eq 'ok') {
                return
            }
        }
        catch {
            Start-Sleep -Milliseconds 200
        }
    }
    throw 'Temporary Go server did not become ready.'
}

try {
    Push-Location $ServerPath
    try {
        & $GoExe build -o $Binary .\cmd\api
        if ($LASTEXITCODE -ne 0) { throw 'Go server build failed.' }
    }
    finally {
        Pop-Location
    }

    $FirstServer = Start-TestServer
    Wait-ServerReady

    $Client = Start-Process `
        -FilePath $DartExe `
        -ArgumentList @('run', '.\tool\reconnect_smoke.dart', "http://127.0.0.1:$Port") `
        -WorkingDirectory $RealtimePath `
        -RedirectStandardOutput $StdoutPath `
        -RedirectStandardError $StderrPath `
        -PassThru `
        -WindowStyle Hidden

    $FirstReady = $false
    for ($Attempt = 0; $Attempt -lt 50; $Attempt++) {
        if (Test-Path -LiteralPath $StdoutPath) {
            $Output = Get-Content -LiteralPath $StdoutPath -Raw -ErrorAction SilentlyContinue
            if ($Output -match 'FIRST_READY') {
                $FirstReady = $true
                break
            }
        }
        $Client.Refresh()
        if ($Client.HasExited) { break }
        Start-Sleep -Milliseconds 200
    }
    if (-not $FirstReady) {
        throw 'Client did not complete its first handshake.'
    }

    Stop-Process -Id $FirstServer.Id -Force
    $FirstServer.WaitForExit()
    $FirstServer = $null
    Start-Sleep -Milliseconds 600

    $SecondServer = Start-TestServer
    Wait-ServerReady

    if (-not $Client.WaitForExit(35000)) {
        throw 'Reconnect test timed out.'
    }

    $Output = Get-Content -LiteralPath $StdoutPath -Raw
    $ErrorOutput = if (Test-Path -LiteralPath $StderrPath) {
        Get-Content -LiteralPath $StderrPath -Raw
    }
    else {
        ''
    }

    Write-Host $Output
    if ($ErrorOutput) {
        Write-Host $ErrorOutput
        throw 'Reconnect client wrote to stderr.'
    }
    if ($Output -notmatch 'RECONNECT_SMOKE_OK') {
        throw 'Reconnect success marker was not produced.'
    }

    Write-Host 'Reconnect smoke test passed.'
}
finally {
    foreach ($Process in @($Client, $FirstServer, $SecondServer)) {
        if ($Process) {
            $Process.Refresh()
            if (-not $Process.HasExited) {
                Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
                $Process.WaitForExit()
            }
        }
    }
    Remove-Item -LiteralPath $Binary, $StdoutPath, $StderrPath -Force -ErrorAction SilentlyContinue
    Remove-Item Env:IM_PORT -ErrorAction SilentlyContinue
}

if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
    throw "Port $Port is still listening after cleanup."
}
