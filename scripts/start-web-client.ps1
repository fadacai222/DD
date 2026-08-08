param(
    [switch]$SkipBuild,
    [switch]$OpenBrowser
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$WebRoot = Join-Path $Root 'clients\app\build\web'
$BuildScript = Join-Path $PSScriptRoot 'build-client.ps1'
$StateDir = Join-Path $Root '.data'
$StateFile = Join-Path $StateDir 'web-client.json'

function Test-PortBindable {
    param([Parameter(Mandatory = $true)][int]$Port)

    $Listener = [System.Net.Sockets.TcpListener]::new(
        [System.Net.IPAddress]::Loopback,
        $Port
    )
    try {
        $Listener.Start()
        return $true
    }
    catch {
        return $false
    }
    finally {
        try { $Listener.Stop() } catch { }
    }
}

function Get-RandomWebPort {
    foreach ($Attempt in 1..200) {
        $Candidate = Get-Random -Minimum 10000 -Maximum 65536
        if (Test-PortBindable -Port $Candidate) {
            return $Candidate
        }
    }
    throw 'Unable to find a bindable local port between 10000 and 65535.'
}

if (Test-Path -LiteralPath $StateFile) {
    try {
        $Existing = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $ExistingProcess = Get-Process -Id ([int]$Existing.pid) -ErrorAction SilentlyContinue
        if ($null -ne $ExistingProcess) {
            $ExistingUrl = "http://127.0.0.1:$($Existing.port)"
            Write-Host "Web client is already running: $ExistingUrl"
            Write-Host "PID: $($Existing.pid)"
            if ($OpenBrowser) {
                Start-Process $ExistingUrl
            }
            exit 0
        }
    }
    catch {
        # Stale or damaged state is replaced below.
    }
    Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
}

if (-not $SkipBuild) {
    & $BuildScript -Target web
    if ($LASTEXITCODE -ne 0) {
        throw 'Web release build failed.'
    }
}

$IndexFile = Join-Path $WebRoot 'index.html'
if (-not (Test-Path -LiteralPath $IndexFile)) {
    throw "Web build not found: $IndexFile. Run without -SkipBuild first."
}

$Python = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $Python) {
    $Python = Get-Command python -ErrorAction SilentlyContinue
}
if ($null -eq $Python) {
    throw 'Python 3 is required to serve the local Web release build.'
}

$Port = Get-RandomWebPort
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
$StdoutLog = Join-Path $StateDir 'web-client.stdout.log'
$StderrLog = Join-Path $StateDir 'web-client.stderr.log'
Remove-Item -LiteralPath $StdoutLog, $StderrLog -Force -ErrorAction SilentlyContinue

$Process = Start-Process `
    -FilePath $Python.Source `
    -ArgumentList @('-m', 'http.server', "$Port", '--bind', '127.0.0.1') `
    -WorkingDirectory $WebRoot `
    -RedirectStandardOutput $StdoutLog `
    -RedirectStandardError $StderrLog `
    -WindowStyle Hidden `
    -PassThru

try {
    $Ready = $false
    foreach ($Attempt in 1..30) {
        Start-Sleep -Milliseconds 100
        if ($Process.HasExited) {
            $ErrorTail = ''
            if (Test-Path -LiteralPath $StderrLog) {
                $ErrorTail = (Get-Content -LiteralPath $StderrLog -Tail 20 -ErrorAction SilentlyContinue) -join [Environment]::NewLine
            }
            if ([string]::IsNullOrWhiteSpace($ErrorTail)) {
                throw "Web server exited early with code $($Process.ExitCode). See $StderrLog"
            }
            throw "Web server exited early with code $($Process.ExitCode):`n$ErrorTail"
        }
        if ($null -ne (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            $Ready = $true
            break
        }
    }
    if (-not $Ready) {
        throw "Web server did not listen on port $Port within 3 seconds."
    }

    [pscustomobject]@{
        pid       = $Process.Id
        port      = $Port
        startedAt = (Get-Date).ToString('o')
        executable = $Python.Source
        webRoot   = $WebRoot
        stdoutLog = $StdoutLog
        stderrLog = $StderrLog
    } | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8

    $Url = "http://127.0.0.1:$Port"
    Write-Host 'Web release client started.'
    Write-Host "URL: $Url"
    Write-Host "PID: $($Process.Id)"
    Write-Host 'Stop: powershell -ExecutionPolicy Bypass -File .\scripts\stop-web-client.ps1'

    if ($OpenBrowser) {
        Start-Process $Url
    }
}
catch {
    Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    throw
}
