$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$AppRoot = Join-Path $Root 'clients\app'
$WindowsRelease = Join-Path $AppRoot 'build\windows\x64\runner\Release'
$WindowsExe = Join-Path $WindowsRelease 'im_client.exe'
$AndroidApk = Join-Path $AppRoot 'build\app\outputs\flutter-apk\app-release.apk'
$WebIndex = Join-Path $AppRoot 'build\web\index.html'
$WebLauncher = Join-Path $PSScriptRoot 'start-dd-web.ps1'

foreach ($required in @($WindowsExe, $AndroidApk, $WebIndex, $WebLauncher)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "发布产物缺失：$required"
    }
}

$rootApk = Join-Path $Root 'DD-Android.apk'
Copy-Item -LiteralPath $AndroidApk -Destination $rootApk -Force

$shell = New-Object -ComObject WScript.Shell

$windowsShortcutPath = Join-Path $Root 'DD-Windows.lnk'
$windowsShortcut = $shell.CreateShortcut($windowsShortcutPath)
$windowsShortcut.TargetPath = $WindowsExe
$windowsShortcut.WorkingDirectory = $WindowsRelease
$windowsShortcut.IconLocation = "$WindowsExe,0"
$windowsShortcut.Description = 'DD Windows Release'
$windowsShortcut.Save()

$webShortcutPath = Join-Path $Root 'DD-Web.lnk'
$webShortcut = $shell.CreateShortcut($webShortcutPath)
$webShortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$webShortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$WebLauncher`""
$webShortcut.WorkingDirectory = $Root
$webShortcut.IconLocation = "$WindowsExe,0"
$webShortcut.Description = 'DD Web Release'
$webShortcut.Save()

Write-Host "DD_ANDROID_APK=$rootApk"
Write-Host "DD_WINDOWS_SHORTCUT=$windowsShortcutPath"
Write-Host "DD_WEB_SHORTCUT=$webShortcutPath"
