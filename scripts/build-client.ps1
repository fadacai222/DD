param(
    [ValidateSet('all', 'windows', 'web', 'android')]
    [string]$Target = 'all',
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$AppPath = Join-Path $Root 'clients\app'
$FlutterExe = 'C:\dev\flutter\bin\flutter.bat'
$JavaHome = 'C:\Program Files\Microsoft\jdk-21.0.12.8-hotspot'
$RootWindowsShortcut = Join-Path $Root 'DD-Windows.lnk'
$RootWebShortcut = Join-Path $Root 'DD-Web.lnk'
$RootAndroidApk = Join-Path $Root 'DD-Android.apk'

if (-not (Test-Path -LiteralPath $FlutterExe)) {
    throw "Flutter not found: $FlutterExe"
}
if (-not (Test-Path -LiteralPath $JavaHome)) {
    throw "JDK not found: $JavaHome"
}
$BrandGenerator = Join-Path $PSScriptRoot 'generate-brand-assets.ps1'
if (-not (Test-Path -LiteralPath $BrandGenerator)) {
    throw "Brand asset generator not found: $BrandGenerator"
}
& $BrandGenerator
$DeveloperMode = Get-ItemPropertyValue `
    -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' `
    -Name 'AllowDevelopmentWithoutDevLicense' `
    -ErrorAction SilentlyContinue
if ($DeveloperMode -ne 1) {
    throw 'Windows Developer Mode is required for Flutter plugins. Run .\scripts\enable-windows-developer-mode.ps1 first.'
}
$env:JAVA_HOME = $JavaHome

function Invoke-Flutter {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )

    Push-Location $WorkingDirectory
    try {
        & $FlutterExe @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw $FailureMessage
        }
    }
    finally {
        Pop-Location
    }
}

function Invoke-FlutterPubGet {
    Push-Location $AppPath
    try {
        $Output = @(& $FlutterExe pub get 2>&1)
        $ExitCode = $LASTEXITCODE
        if ($ExitCode -ne 0) {
            $Output | ForEach-Object { Write-Host $_ }
            throw 'Flutter pub get failed.'
        }

        foreach ($Line in $Output) {
            $Text = [string]$Line
            if ($Text -match '^\s{2,}\S.+\([^\r\n]+ available\)$') { continue }
            if ($Text -match '^\d+ packages have newer versions incompatible with dependency constraints\.$') { continue }
            if ($Text -match '^Try `flutter pub outdated` for more information\.$') { continue }
            Write-Host $Text
        }
    }
    finally {
        Pop-Location
    }
}

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
    throw 'No free drive letter is available for the Windows build workaround.'
}

function Assert-WindowsATL {
    $VsWhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $VsWhere)) {
        throw "Visual Studio Installer tool not found: $VsWhere"
    }

    $VsPath = ((& $VsWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath) -join '').Trim()
    if ([string]::IsNullOrWhiteSpace($VsPath)) {
        throw 'Visual Studio Build Tools with Desktop C++ tools is required for the Windows client.'
    }

    $AtlHeader = Get-ChildItem -Path (Join-Path $VsPath 'VC\Tools\MSVC\*\atlmfc\include\atlstr.h') -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $AtlHeader) {
        $Setup = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\setup.exe'
        throw "Windows build dependency missing: ATL (atlstr.h). flutter_secure_storage_windows requires Microsoft.VisualStudio.Component.VC.ATL. Open an elevated PowerShell once and run: & '$Setup' modify --installPath '$VsPath' --add Microsoft.VisualStudio.Component.VC.ATL --passive --norestart"
    }
}

function Test-WindowsFlutterGeneratedState {
    param([Parameter(Mandatory = $true)][string]$AppRoot)

    $RequiredPaths = @(
        'windows\flutter\ephemeral\flutter_windows.dll',
        'windows\flutter\ephemeral\flutter_windows.dll.lib',
        'windows\flutter\ephemeral\icudtl.dat',
        'windows\flutter\ephemeral\cpp_client_wrapper\core_implementations.cc',
        'windows\flutter\ephemeral\cpp_client_wrapper\standard_codec.cc',
        'windows\flutter\ephemeral\cpp_client_wrapper\plugin_registrar.cc',
        'windows\flutter\ephemeral\cpp_client_wrapper\flutter_engine.cc',
        'windows\flutter\ephemeral\cpp_client_wrapper\flutter_view_controller.cc',
        'windows\flutter\ephemeral\cpp_client_wrapper\include\flutter\flutter_view_controller.h'
    )
    foreach ($RelativePath in $RequiredPaths) {
        if (-not (Test-Path -LiteralPath (Join-Path $AppRoot $RelativePath))) {
            return $false
        }
    }

    $GeneratedConfig = Join-Path $AppRoot 'windows\flutter\ephemeral\generated_config.cmake'
    if (-not (Test-Path -LiteralPath $GeneratedConfig)) {
        return $false
    }
    $ConfigText = Get-Content -LiteralPath $GeneratedConfig -Raw -Encoding UTF8
    if ($ConfigText -notmatch 'file\(TO_CMAKE_PATH "([^"]+)" PROJECT_DIR\)') {
        return $false
    }
    $ConfiguredProjectDir = $Matches[1].Replace('\\', '\').TrimEnd('\')
    return $ConfiguredProjectDir -ieq $AppRoot.TrimEnd('\')
}

function Remove-WindowsGeneratedDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    foreach ($Attempt in 1..20) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Path)) { return }
        # MSBuild/Defender can retain short-lived handles on .tlog/object files
        # for a moment after a failed build. Give those handles time to drain.
        Start-Sleep -Milliseconds 500
    }
    throw "Unable to clear stale Windows build cache: $Path"
}

function Reset-WindowsFlutterGeneratedState {
    param([Parameter(Mandatory = $true)][string]$AppRoot)

    Write-Host 'Repairing stale Flutter Windows generated state...'

    # Always clear through the short subst path. Removing these trees through the
    # original Chinese/long project path can partially fail on deep CMake/NuGet
    # paths and leave a mixed-drive cache behind.
    Remove-WindowsGeneratedDirectory (Join-Path $AppRoot 'build\windows')
    Remove-WindowsGeneratedDirectory (Join-Path $AppRoot 'windows\flutter\ephemeral')

    # Flutter 3.44 native-asset hooks persist absolute project paths outside the
    # Windows depfile cache. If a previous build used O: and this build uses P:,
    # stale hook input.json files can make dart_build try to create the old drive.
    # Keep package_config/pub dependencies, but discard all path-sensitive build
    # intermediates so Flutter can regenerate them for the current subst drive.
    Remove-WindowsGeneratedDirectory (Join-Path $AppRoot '.dart_tool\flutter_build')
    Remove-WindowsGeneratedDirectory (Join-Path $AppRoot '.dart_tool\hooks_runner')
}

function Build-Windows {
    Assert-WindowsATL
    $BuildStartedAtUtc = [DateTime]::UtcNow
    $Drive = Get-FreeSubstDrive
    & subst.exe $Drive $Root
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to map $Drive to the project root."
    }

    try {
        $MappedApp = "$Drive\clients\app"
        if (-not (Test-WindowsFlutterGeneratedState -AppRoot $MappedApp)) {
            Reset-WindowsFlutterGeneratedState -AppRoot $MappedApp
        }

        try {
            Invoke-Flutter @('build', 'windows', '--release', '--no-pub') $MappedApp 'Windows release build failed.'
        }
        catch {
            if (Test-WindowsFlutterGeneratedState -AppRoot $MappedApp) {
                throw
            }
            Write-Host 'Windows generated files disappeared during build; resetting the Windows cache and retrying once...'
            Reset-WindowsFlutterGeneratedState -AppRoot $MappedApp
            Invoke-Flutter @('build', 'windows', '--release', '--no-pub') $MappedApp 'Windows release build failed after cache repair.'
        }

        $WindowsExe = Join-Path $MappedApp 'build\windows\x64\runner\Release\im_client.exe'
        if (-not (Test-Path -LiteralPath $WindowsExe)) {
            throw 'Windows build reported success, but im_client.exe was not produced.'
        }
        $Artifact = Get-Item -LiteralPath $WindowsExe
        if ($Artifact.LastWriteTimeUtc -lt $BuildStartedAtUtc.AddSeconds(-2)) {
            throw "Windows build returned success but the release executable is stale: $($Artifact.LastWriteTime). Refusing to publish an old client."
        }
        Write-Host "Fresh Windows artifact: $WindowsExe ($($Artifact.LastWriteTime))"
    }
    finally {
        Set-Location 'C:\'
        & subst.exe $Drive /D | Out-Null
    }
}

function Build-Web {
    Invoke-Flutter @('build', 'web', '--release', '--no-pub', '--no-wasm-dry-run') $AppPath 'Web release build failed.'
}

function Test-KnownAndroidKgpStack {
    $LockFile = Join-Path $AppPath 'pubspec.lock'
    if (-not (Test-Path -LiteralPath $LockFile)) { return $false }

    $LockText = Get-Content -LiteralPath $LockFile -Raw -Encoding UTF8
    return `
        ($LockText -match '(?ms)^  desktop_drop:.*?^    version: "0\.7\.1"\s*$') -and `
        ($LockText -match '(?ms)^  livekit_client:.*?^    version: "2\.10\.0"\s*$') -and `
        ($LockText -match '(?ms)^  flutter_webrtc:.*?^    version: "1\.6\.0"\s*$') -and `
        ($LockText -match '(?ms)^  device_info_plus:.*?^    version: "12\.4\.0"\s*$')
}

function Invoke-FlutterAndroidBuild {
    Push-Location $AppPath
    try {
        # Windows PowerShell 5.1 converts native stderr into ErrorRecord objects.
        # Temporarily use Continue so Flutter warnings can be captured and filtered;
        # the real success/failure decision still comes from the native exit code.
        $PreviousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $Output = @(& $FlutterExe build apk --debug --no-pub 2>&1)
            $ExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $PreviousErrorActionPreference
        }
        if ($ExitCode -ne 0) {
            $Output | ForEach-Object { Write-Host $_ }
            throw 'Android debug APK build failed.'
        }

        # Flutter 3.44+ warns because this exact current LiveKit dependency stack
        # still applies legacy KGP under AGP 9. Only suppress the known warning
        # while these locked versions match; dependency changes make it visible again.
        $KnownKgpStack = Test-KnownAndroidKgpStack
        $SuppressKnownKgpWarning = $false
        foreach ($Line in $Output) {
            $Text = [string]$Line
            if ($KnownKgpStack -and $Text -match 'WARNING: Your app uses the following plugins that apply Kotlin Gradle Plugin \(KGP\): desktop_drop, device_info_plus, flutter_webrtc, livekit_client') {
                $SuppressKnownKgpWarning = $true
                continue
            }
            if ($SuppressKnownKgpWarning) {
                if ($Text -match "Running Gradle task 'assembleDebug'" -or $Text -match 'Built build\\app\\outputs') {
                    $SuppressKnownKgpWarning = $false
                }
                else {
                    continue
                }
            }
            if ($Text -match "^Running Gradle task 'assembleDebug'\.\.\.\s*$") { continue }
            if ($Text -match 'Built build\\app\\outputs\\flutter-apk\\app-debug\.apk') {
                Write-Host 'Built Android APK: build\app\outputs\flutter-apk\app-debug.apk'
                continue
            }
            Write-Host $Text
        }
    }
    finally {
        Pop-Location
    }
}

function Set-RootShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$ShortcutPath,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [string]$Arguments = '',
        [string]$WorkingDirectory = '',
        [string]$IconLocation = ''
    )

    $Shell = New-Object -ComObject WScript.Shell
    try {
        $Shortcut = $Shell.CreateShortcut($ShortcutPath)
        $Shortcut.TargetPath = $TargetPath
        $Shortcut.Arguments = $Arguments
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $Shortcut.WorkingDirectory = $WorkingDirectory
        }
        if (-not [string]::IsNullOrWhiteSpace($IconLocation)) {
            $Shortcut.IconLocation = $IconLocation
        }
        $Shortcut.Save()
    }
    finally {
        if ($null -ne $Shell) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Shell)
        }
    }
}

function Publish-RootClientArtifacts {
    $WindowsExe = Join-Path $AppPath 'build\windows\x64\runner\Release\im_client.exe'
    if (Test-Path -LiteralPath $WindowsExe) {
        Set-RootShortcut `
            -ShortcutPath $RootWindowsShortcut `
            -TargetPath $WindowsExe `
            -WorkingDirectory (Split-Path -Parent $WindowsExe) `
            -IconLocation $WindowsExe
        Write-Host "Root shortcut: $RootWindowsShortcut"
    }

    $WebIndex = Join-Path $AppPath 'build\web\index.html'
    $StartWebScript = Join-Path $PSScriptRoot 'start-web-client.ps1'
    if ((Test-Path -LiteralPath $WebIndex) -and (Test-Path -LiteralPath $StartWebScript)) {
        $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $WebArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$StartWebScript`" -SkipBuild -OpenBrowser"
        Set-RootShortcut `
            -ShortcutPath $RootWebShortcut `
            -TargetPath $PowerShellExe `
            -Arguments $WebArguments `
            -WorkingDirectory $Root
        Write-Host "Root shortcut: $RootWebShortcut"
    }

    $BuiltApk = Join-Path $AppPath 'build\app\outputs\flutter-apk\app-debug.apk'
    if (Test-Path -LiteralPath $BuiltApk) {
        Copy-Item -LiteralPath $BuiltApk -Destination $RootAndroidApk -Force
        Write-Host "Root Android APK: $RootAndroidApk"
    }
}

function Build-Android {
    Invoke-FlutterAndroidBuild

    $StableApk = Join-Path $AppPath 'build\app\outputs\flutter-apk\app-debug.apk'
    if (Test-Path -LiteralPath $StableApk) {
        return
    }

    $GradleApk = Join-Path $AppPath 'build\app\outputs\apk\debug\app-debug.apk'
    if (-not (Test-Path -LiteralPath $GradleApk)) {
        throw 'Android build reported success, but app-debug.apk was not found in any known Flutter/Gradle output path.'
    }

    $StableDir = Split-Path -Parent $StableApk
    New-Item -ItemType Directory -Path $StableDir -Force | Out-Null
    Copy-Item -LiteralPath $GradleApk -Destination $StableApk -Force
    Write-Host "Normalized Android APK path: $StableApk"
}

if ($Clean) {
    $WebStateFile = Join-Path $Root '.data\web-client.json'
    if (Test-Path -LiteralPath $WebStateFile) {
        throw 'Web client is running. Stop it with .\scripts\stop-web-client.ps1 before using -Clean.'
    }
    Invoke-Flutter @('clean') $AppPath 'Flutter clean failed.'
}

Invoke-FlutterPubGet

switch ($Target) {
    'windows' { Build-Windows }
    'web' { Build-Web }
    'android' { Build-Android }
    'all' {
        Build-Windows
        Build-Web
        Build-Android
    }
}

Publish-RootClientArtifacts

Write-Host 'Build complete.'
Write-Host "Windows: $AppPath\build\windows\x64\runner\Release\im_client.exe"
Write-Host "Web:     $AppPath\build\web"
Write-Host "Android: $AppPath\build\app\outputs\flutter-apk\app-debug.apk"
