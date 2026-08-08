param(
    [Parameter(Mandatory = $true)][string]$LanIP,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RuleGroup = 'DD Auth Dev LAN'
$RuleName = 'DD Auth Dev LAN TCP'
$UdpRuleName = 'DD Auth Dev LAN UDP'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedSelf {
    $removeArgument = if ($Remove) { ' -Remove' } else { '' }
    $argumentLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -LanIP "{1}"{2}' -f $PSCommandPath, $LanIP, $removeArgument
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -Verb RunAs -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Administrator firewall configuration failed with exit code $($process.ExitCode)."
    }
}

if (-not (Test-IsAdministrator)) {
    Invoke-ElevatedSelf
    exit 0
}

$existing = Get-NetFirewallRule -Group $RuleGroup -ErrorAction SilentlyContinue
if ($existing) {
    $existing | Remove-NetFirewallRule
}

if ($Remove) {
    Write-Host 'DD Auth Dev LAN firewall rule removed.'
    exit 0
}

New-NetFirewallRule `
    -DisplayName $RuleName `
    -Group $RuleGroup `
    -Direction Inbound `
    -Action Allow `
    -Enabled True `
    -Profile Private `
    -Protocol TCP `
    -LocalAddress $LanIP `
    -LocalPort 18473,17880,17881,19000 `
    -RemoteAddress LocalSubnet `
    -EdgeTraversalPolicy Block | Out-Null

New-NetFirewallRule `
    -DisplayName $UdpRuleName `
    -Group $RuleGroup `
    -Direction Inbound `
    -Action Allow `
    -Enabled True `
    -Profile Private `
    -Protocol UDP `
    -LocalAddress $LanIP `
    -LocalPort 17882,13478 `
    -RemoteAddress LocalSubnet `
    -EdgeTraversalPolicy Block | Out-Null

Write-Host "DD Auth Dev firewall ready for API + LiveKit + private media on $LanIP (Private + LocalSubnet only)."
