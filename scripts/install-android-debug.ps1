param(
    [switch]$SkipBuild,
    [switch]$Launch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$BuildScript = Join-Path $PSScriptRoot 'build-client.ps1'
$Apk = Join-Path $Root 'clients\app\build\app\outputs\flutter-apk\app-debug.apk'
$PackageName = 'org.openimx.client'

function Find-Adb {
    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Genymobile.scrcpy_Microsoft.Winget.Source_8wekyb3d8bbwe\scrcpy-win64-v3.3.4\adb.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    throw 'adb.exe was not found. Install Android platform-tools or scrcpy first.'
}

if (-not $SkipBuild) {
    & $BuildScript -Target android
    if ($LASTEXITCODE -ne 0) { throw 'Android Debug APK build failed.' }
}
if (-not (Test-Path -LiteralPath $Apk)) {
    throw "APK not found: $Apk"
}

$Adb = Find-Adb
& $Adb start-server *> $null
if ($LASTEXITCODE -ne 0) { throw 'adb server failed to start.' }

$deviceLines = @(& $Adb devices | Select-Object -Skip 1 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$unauthorized = @($deviceLines | Where-Object { $_ -match '\sunauthorized$' })
if ($unauthorized.Count -gt 0) {
    throw 'Android device is connected but not authorized. Unlock the phone and accept the USB debugging authorization prompt.'
}

$devices = @($deviceLines | Where-Object { $_ -match '\sdevice$' })
if ($devices.Count -eq 0) {
    throw 'No authorized Android device found. Connect the phone by USB, enable Developer options + USB debugging, then rerun.'
}
if ($devices.Count -gt 1) {
    throw "Multiple Android devices are connected ($($devices.Count)). Disconnect extra devices so the APK cannot be installed to the wrong target."
}

$serial = ($devices[0] -split '\s+')[0]
Write-Host "Installing APK to Android device: $serial"
& $Adb -s $serial install -r -t $Apk
if ($LASTEXITCODE -ne 0) { throw 'adb install failed.' }

Write-Host 'Android Debug APK installed successfully.'
if ($Launch) {
    & $Adb -s $serial shell monkey -p $PackageName -c android.intent.category.LAUNCHER 1 *> $null
    if ($LASTEXITCODE -ne 0) { throw 'APK installed, but automatic launch failed.' }
    Write-Host 'Android app launched.'
}
