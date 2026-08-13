param(
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$AppRoot = Join-Path $Root 'clients\app'

if (-not (Test-Path -LiteralPath $AppRoot)) {
    throw "Client app directory not found: $AppRoot"
}

function Get-DirectoryBytes {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
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
    Where-Object { Test-Path -LiteralPath $_ } |
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
$items = foreach ($target in $uniqueTargets) {
    $bytes = Get-DirectoryBytes -Path $target
    $totalBefore += $bytes
    [PSCustomObject]@{
        Size = Format-Bytes -Bytes $bytes
        Path = $target.Substring($Root.Length).TrimStart('\')
        FullPath = $target
        Bytes = $bytes
    }
}

$items | Sort-Object Bytes -Descending | Format-Table Size, Path -AutoSize
Write-Host ''
Write-Host ("Total removable: {0}" -f (Format-Bytes -Bytes $totalBefore)) -ForegroundColor Yellow
Write-Host 'Only generated build/cache directories listed above will be removed.'
Write-Host 'Source code, Git files, config, signing material and dependencies are preserved.'
Write-Host ''

$failed = New-Object System.Collections.Generic.List[string]
foreach ($item in $items) {
    Write-Host ("Removing {0} ..." -f $item.Path)
    try {
        Remove-Item -LiteralPath $item.FullPath -Recurse -Force -ErrorAction Stop
    }
    catch {
        $failed.Add("$($item.Path): $($_.Exception.Message)")
    }
}

$remaining = [int64]0
foreach ($item in $items) {
    if (Test-Path -LiteralPath $item.FullPath) {
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
    Write-Host 'Some paths could not be fully removed (usually because a client/build process is still running):' -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host 'Close DD/Flutter build processes and run this cleaner again.' -ForegroundColor Yellow
    exit 1
}

Write-Host 'Cleanup complete.' -ForegroundColor Green
