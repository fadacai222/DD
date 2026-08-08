$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$StateFile = Join-Path $Root '.data\web-client.json'

if (-not (Test-Path -LiteralPath $StateFile)) {
    Write-Host 'Web client is not running (no state file found).'
    exit 0
}

try {
    $State = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $ProcessId = [int]$State.pid
    $Port = [int]$State.port
}
catch {
    Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    throw 'Web client state file was invalid and has been removed.'
}

$ProcessInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
if ($null -eq $ProcessInfo) {
    Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    Write-Host 'Web client process was already stopped; stale state removed.'
    exit 0
}

$CommandLine = [string]$ProcessInfo.CommandLine
if ($CommandLine -notmatch 'http\.server' -or $CommandLine -notmatch [regex]::Escape([string]$Port)) {
    Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    throw "PID $ProcessId no longer matches the recorded Web server. No process was killed; stale state was removed."
}

Stop-Process -Id $ProcessId -Force -ErrorAction Stop
Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
Write-Host "Web release client stopped. PID: $ProcessId, port: $Port"
