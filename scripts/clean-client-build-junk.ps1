param(
    [switch]$NoPause,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$AppRoot = Join-Path $Root 'clients\app'

if (-not [System.IO.Directory]::Exists($AppRoot)) {
    throw "Client app directory not found: $AppRoot"
}

function Get-DirectoryBytes {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [System.IO.Directory]::Exists($Path)) { return [int64]0 }

    $sum = Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum
    if ($null -eq $sum.Sum) { return [int64]0 }
    return [int64]$sum.Sum
}

function Format-Bytes {
    param([Parameter(Mandatory = $true)][int64]$Bytes)

    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Assert-SafeDeletePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $rootPrefix = $Root + '\'

    if (-not $full.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to delete path outside repository: $full"
    }
    if ($full.Equals($Root, [System.StringComparison]::OrdinalIgnoreCase) -or
        $full.Equals($AppRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to delete protected project path: $full"
    }
}

function Invoke-GitCleanDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-SafeDeletePath -Path $Path
    if (-not [System.IO.Directory]::Exists($Path)) { return }

    if ($null -eq (Get-Command git.exe -ErrorAction SilentlyContinue)) {
        throw 'Git for Windows is required for long-path-safe cleanup.'
    }

    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $relative = $full.Substring($Root.Length).TrimStart('\').Replace('\', '/')
    $gitOutput = @()
    $gitExitCode = -1

    Push-Location $Root
    try {
        $gitOutput = @(& git.exe -c core.longpaths=true clean -fdx -- $relative 2>&1)
        $gitExitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($gitExitCode -ne 0) {
        $details = ($gitOutput | ForEach-Object { [string]$_ }) -join '; '
        throw "git clean failed (exit=$gitExitCode): $details"
    }

    if ([System.IO.Directory]::Exists($Path)) {
        throw "Path remains after git clean. It may contain a tracked file or a file locked by another process: $Path"
    }
}

function Stop-GradleDaemons {
    $gradleWrapper = Join-Path $AppRoot 'android\gradlew.bat'
    if (-not [System.IO.File]::Exists($gradleWrapper)) { return }

    Write-Host 'Stopping Gradle daemons ...'
    try {
        Push-Location (Split-Path -Parent $gradleWrapper)
        try {
            & $gradleWrapper --stop *> $null
        }
        finally {
            Pop-Location
        }
    }
    catch {
        Write-Host ("Gradle daemon stop was skipped: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Stop-ProcessesInsideTargets {
    param([Parameter(Mandatory = $true)][object[]]$Items)

    try {
        $processes = Get-CimInstance Win32_Process -ErrorAction Stop |
            Where-Object { $null -ne $_.ExecutablePath -and $_.ProcessId -ne $PID }
    }
    catch {
        Write-Host ("Could not inspect running process paths: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        return
    }

    foreach ($process in $processes) {
        $exePath = [string]$process.ExecutablePath
        foreach ($item in $Items) {
            $target = ([System.IO.Path]::GetFullPath([string]$item.FullPath)).TrimEnd('\')
            $targetPrefix = $target + '\'
            if ($exePath.Equals($target, [System.StringComparison]::OrdinalIgnoreCase) -or
                $exePath.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                try {
                    Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
                    Write-Host ("Stopped build-output process: {0} (PID {1})" -f $process.Name, $process.ProcessId) -ForegroundColor Yellow
                }
                catch {
                    Write-Host ("Could not stop {0} (PID {1}): {2}" -f $process.Name, $process.ProcessId, $_.Exception.Message) -ForegroundColor Yellow
                }
                break
            }
        }
    }
}

$targets = New-Object System.Collections.Generic.List[string]

# Main Flutter build output.
$targets.Add((Join-Path $AppRoot 'build'))

# Historical/temporary Windows build trees created while working around
# Chinese/long-path and GPU build issues. These are fully reproducible.
Get-ChildItem -LiteralPath $AppRoot -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'build_win_*' -or $_.Name -like 'build_windows_*' } |
    ForEach-Object { $targets.Add($_.FullName) }

# Reproducible Flutter/Windows/Android generated caches only. Do not delete
# pubspec.lock, platform source, signing files, Gradle wrapper, Pods, or user data.
foreach ($relative in @(
    '.dart_tool\flutter_build',
    '.dart_tool\hooks_runner',
    'windows\flutter\ephemeral',
    'android\.gradle',
    'android\.kotlin',
    'android\.cxx'
)) {
    $targets.Add((Join-Path $AppRoot $relative))
}

$uniqueTargets = $targets |
    Where-Object { [System.IO.Directory]::Exists($_) } |
    Sort-Object -Unique

Write-Host ''
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host '      DD Client Build Junk Cleaner' -ForegroundColor Cyan
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host ''

if (-not $uniqueTargets) {
    Write-Host 'No removable client build junk was found.' -ForegroundColor Green
    exit 0
}

$totalBefore = [int64]0
$items = @(
    foreach ($target in $uniqueTargets) {
        $bytes = Get-DirectoryBytes -Path $target
        $totalBefore += $bytes
        [PSCustomObject]@{
            Size = Format-Bytes -Bytes $bytes
            Path = $target.Substring($Root.Length).TrimStart('\')
            FullPath = $target
            Bytes = $bytes
        }
    }
)

$items | Sort-Object Bytes -Descending | Format-Table Size, Path -AutoSize
Write-Host ''
Write-Host ("Total removable: {0}" -f (Format-Bytes -Bytes $totalBefore)) -ForegroundColor Yellow
Write-Host 'Only generated build/cache directories listed above will be removed.'
Write-Host 'Source code, Git files, config, signing material and dependency definitions are preserved.'
Write-Host ''

if ($DryRun) {
    Write-Host 'Dry run only; nothing was removed.' -ForegroundColor Yellow
    exit 0
}

Stop-GradleDaemons
Stop-ProcessesInsideTargets -Items $items

$failed = New-Object System.Collections.Generic.List[string]
foreach ($item in $items) {
    Write-Host ("Removing {0} ..." -f $item.Path)
    try {
        Invoke-GitCleanDirectory -Path $item.FullPath
    }
    catch {
        $failed.Add("$($item.Path): $($_.Exception.Message)")
    }
}

$remaining = [int64]0
foreach ($item in $items) {
    if ([System.IO.Directory]::Exists($item.FullPath)) {
        $remaining += Get-DirectoryBytes -Path $item.FullPath
    }
}
$freed = [Math]::Max([int64]0, $totalBefore - $remaining)

Write-Host ''
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host ("Freed approximately: {0}" -f (Format-Bytes -Bytes $freed)) -ForegroundColor Green
if ($remaining -gt 0) {
    Write-Host ("Still remaining in targeted paths: {0}" -f (Format-Bytes -Bytes $remaining)) -ForegroundColor Yellow
}
if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host 'Some generated paths could not be fully removed:' -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host 'If a path remains, a process outside the build output may still have a file open.' -ForegroundColor Yellow
    exit 1
}

Write-Host 'Cleanup complete.' -ForegroundColor Green
