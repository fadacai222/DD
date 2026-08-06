param(
    [ValidateSet('all', 'windows', 'web', 'android')]
    [string]$Target = 'all'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$AppPath = Join-Path $Root 'clients\app'
$FlutterExe = 'C:\dev\flutter\bin\flutter.bat'
$JavaHome = 'C:\Program Files\Microsoft\jdk-21.0.12.8-hotspot'

if (-not (Test-Path -LiteralPath $FlutterExe)) {
    throw "Flutter not found: $FlutterExe"
}
if (-not (Test-Path -LiteralPath $JavaHome)) {
    throw "JDK not found: $JavaHome"
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

function Build-Windows {
    $Drive = Get-FreeSubstDrive
    & subst.exe $Drive $Root
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to map $Drive to the project root."
    }

    try {
        $MappedApp = "$Drive\clients\app"
        Invoke-Flutter @('clean') $MappedApp 'Flutter clean failed for Windows.'
        Invoke-Flutter @('pub', 'get') $MappedApp 'Flutter pub get failed for Windows.'
        Invoke-Flutter @('build', 'windows', '--release') $MappedApp 'Windows release build failed.'
    }
    finally {
        Set-Location 'C:\'
        & subst.exe $Drive /D | Out-Null
    }
}

function Build-Web {
    Invoke-Flutter @('build', 'web', '--release') $AppPath 'Web release build failed.'
}

function Build-Android {
    Invoke-Flutter @('build', 'apk', '--debug') $AppPath 'Android debug APK build failed.'
}

Invoke-Flutter @('pub', 'get') $AppPath 'Flutter pub get failed.'

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

Write-Host 'Build complete.'
Write-Host "Windows: $AppPath\build\windows\x64\runner\Release\im_client.exe"
Write-Host "Web:     $AppPath\build\web"
Write-Host "Android: $AppPath\build\app\outputs\flutter-apk\app-debug.apk"
