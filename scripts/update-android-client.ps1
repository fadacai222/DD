param(
    [string]$Serial = '',
    [switch]$SkipBuild,
    [switch]$NoLaunch,
    [switch]$NoPrompt
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$BuildScript = Join-Path $PSScriptRoot 'build-client.ps1'
$ApkPath = Join-Path $Root 'clients\app\build\app\outputs\flutter-apk\app-debug.apk'
$RootApk = Join-Path $Root 'DD-Android.apk'
$PackageName = 'org.openimx.client'
$MainActivity = 'org.openimx.client/.MainActivity'

function Find-Adb {
    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($null -ne $command -and (Test-Path -LiteralPath $command.Source)) {
        return $command.Source
    }

    $candidates = [System.Collections.Generic.List[string]]::new()

    $localProperties = Join-Path $Root 'clients\app\android\local.properties'
    if (Test-Path -LiteralPath $localProperties) {
        $sdkLine = Get-Content -LiteralPath $localProperties -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '^sdk\.dir=' } |
            Select-Object -First 1
        if ($null -ne $sdkLine) {
            $sdkDir = ([string]$sdkLine).Substring(8).Trim().Replace('\\', '\')
            if (-not [string]::IsNullOrWhiteSpace($sdkDir)) {
                $candidates.Add((Join-Path $sdkDir 'platform-tools\adb.exe'))
            }
        }
    }

    foreach ($sdkRoot in @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)) {
        if (-not [string]::IsNullOrWhiteSpace($sdkRoot)) {
            $candidates.Add((Join-Path $sdkRoot 'platform-tools\adb.exe'))
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'))
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw @'
adb.exe was not found.
Install Android SDK Platform-Tools (Android Studio > SDK Manager > SDK Tools),
or set ANDROID_SDK_ROOT / ANDROID_HOME. DD will detect it automatically next time.
'@
}

$Adb = Find-Adb

function Write-Step {
    param([string]$Text)
    Write-Host "`n==> $Text" -ForegroundColor Cyan
}

function Get-ConnectedDeviceSerials {
    $lines = @(& $Adb devices 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "adb devices failed: $($lines -join ' ')"
    }

    $serials = @()
    foreach ($line in $lines) {
        $text = [string]$line
        if ($text -match '^([^\s]+)\s+device(?:\s|$)') {
            $serials += $Matches[1]
        }
    }
    return @($serials)
}

function Resolve-DeviceSerial {
    $devices = @(Get-ConnectedDeviceSerials)
    if (-not [string]::IsNullOrWhiteSpace($Serial)) {
        if ($devices -notcontains $Serial) {
            throw "Requested Android device is not connected: $Serial"
        }
        return $Serial
    }
    if ($devices.Count -eq 0) {
        throw 'No authorized Android device found. Connect USB, enable USB debugging, and authorize this computer.'
    }
    if ($devices.Count -gt 1) {
        throw "More than one Android device is connected: $($devices -join ', '). Re-run with -Serial <serial>."
    }
    return $devices[0]
}

function Invoke-AdbInstall {
    param(
        [Parameter(Mandatory = $true)][string]$DeviceSerial,
        [Parameter(Mandatory = $true)][string]$Apk
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $Adb -s $DeviceSerial install --no-streaming -r -g $Apk 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    $text = ($output | ForEach-Object { [string]$_ }) -join "`n"
    $output | ForEach-Object { Write-Host ([string]$_) }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = $text
    }
}

function Get-PackageSummary {
    param([Parameter(Mandatory = $true)][string]$DeviceSerial)
    $dump = @(& $Adb -s $DeviceSerial shell dumpsys package $PackageName 2>&1)
    if ($LASTEXITCODE -ne 0) {
        return @('Package metadata unavailable.')
    }
    return @($dump | Where-Object {
        ([string]$_) -match 'versionCode=|versionName=|firstInstallTime=|lastUpdateTime='
    } | Select-Object -First 8)
}

Write-Host 'DD Android one-click updater' -ForegroundColor Green
Write-Host "Project: $Root"
Write-Host "ADB: $Adb"

Write-Step 'Checking ADB device'
& $Adb start-server | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "ADB server failed to start: $Adb"
}
$DeviceSerial = Resolve-DeviceSerial
$model = ((& $Adb -s $DeviceSerial shell getprop ro.product.model 2>$null) -join '').Trim()
Write-Host "Device: $DeviceSerial $model"

if (-not $SkipBuild) {
    Write-Step 'Building the latest DD Android APK'
    if (-not (Test-Path -LiteralPath $BuildScript)) {
        throw "Build script not found: $BuildScript"
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $BuildScript -Target android
    if ($LASTEXITCODE -ne 0) {
        throw "Android build failed with exit code $LASTEXITCODE."
    }
}

if (-not (Test-Path -LiteralPath $ApkPath)) {
    throw "Built APK not found: $ApkPath"
}

Copy-Item -LiteralPath $ApkPath -Destination $RootApk -Force
$apk = Get-Item -LiteralPath $ApkPath
$hash = (Get-FileHash -LiteralPath $ApkPath -Algorithm SHA256).Hash
Write-Host "APK: $($apk.FullName)"
Write-Host "APK time: $($apk.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "APK bytes: $($apk.Length)"
Write-Host "APK SHA256: $hash"

Write-Step 'Installing over the existing app (app data is preserved)'
$install = Invoke-AdbInstall -DeviceSerial $DeviceSerial -Apk $ApkPath
if ($install.ExitCode -ne 0 -and $install.Text -match 'INSTALL_FAILED_ABORTED|User rejected|user rejected|INSTALL_CANCELED_BY_USER') {
    if ($NoPrompt) {
        throw 'Phone-side USB install permission/confirmation was rejected. Allow the install prompt on the phone and run the updater again.'
    }
    Write-Host ''
    Write-Host 'The phone blocked or rejected USB installation.' -ForegroundColor Yellow
    Write-Host 'On the phone, allow USB installation / confirm the install, then return here.' -ForegroundColor Yellow
    [void](Read-Host 'Press Enter to retry installation')
    $install = Invoke-AdbInstall -DeviceSerial $DeviceSerial -Apk $ApkPath
}
if ($install.ExitCode -ne 0) {
    throw "ADB install failed with exit code $($install.ExitCode)."
}

Write-Step 'Verifying installed package'
Get-PackageSummary -DeviceSerial $DeviceSerial | ForEach-Object { Write-Host ([string]$_).Trim() }

if (-not $NoLaunch) {
    Write-Step 'Restarting DD on the phone'
    & $Adb -s $DeviceSerial shell am force-stop $PackageName | Out-Null
    $launch = @(& $Adb -s $DeviceSerial shell am start -n $MainActivity 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $launch | ForEach-Object { Write-Host ([string]$_) }
        throw 'DD was installed, but automatic launch failed.'
    }
    Start-Sleep -Milliseconds 800
    $pidText = ((& $Adb -s $DeviceSerial shell pidof $PackageName 2>$null) -join '').Trim()
    Write-Host "Running PID: $pidText"
}

Write-Host ''
Write-Host 'DD Android update completed successfully.' -ForegroundColor Green
Write-Host "Root APK refreshed: $RootApk"
