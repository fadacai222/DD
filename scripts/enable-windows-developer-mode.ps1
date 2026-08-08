$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$ValueName = 'AllowDevelopmentWithoutDevLicense'

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdministrator) {
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath)
    )
    Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments
    Write-Host 'Administrator confirmation requested. Complete the elevated window.'
    exit 0
}

if (-not (Test-Path -LiteralPath $RegistryPath)) {
    New-Item -Path $RegistryPath -Force | Out-Null
}
Set-ItemProperty `
    -Path $RegistryPath `
    -Name $ValueName `
    -Type DWord `
    -Value 1

$value = (Get-ItemProperty -Path $RegistryPath -Name $ValueName).$ValueName
if ($value -ne 1) {
    throw 'Developer Mode registry value was not applied.'
}

Write-Host 'WINDOWS_DEVELOPER_MODE_ENABLED=true'
Write-Host 'Close and reopen PowerShell, VS Code, and Android Studio before rebuilding.'
