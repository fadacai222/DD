param(
    [Parameter(Mandatory = $true)][string]$LanIP,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RuleGroup = 'OpenIMX Call PoC LAN'
$TcpRuleName = 'OpenIMX Call PoC LAN TCP'
$UdpRuleName = 'OpenIMX Call PoC LAN UDP'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedSelf {
    $removeArgument = if ($Remove) { ' -Remove' } else { '' }
    $argumentLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -LanIP "{1}"{2}' -f $PSCommandPath, $LanIP, $removeArgument

    $process = Start-Process `
        -FilePath 'powershell.exe' `
        -ArgumentList $argumentLine `
        -Verb RunAs `
        -Wait `
        -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Administrator firewall configuration failed with exit code $($process.ExitCode)."
    }
}

if (-not (Test-IsAdministrator)) {
    Invoke-ElevatedSelf
    exit 0
}

$existing = Get-NetFirewallRule -Group $RuleGroup -ErrorAction SilentlyContinue
if ($Remove) {
    if ($existing) {
        $existing | Remove-NetFirewallRule
    }
    Write-Host 'OpenIMX Call PoC LAN firewall rules removed.'
    exit 0
}

if ($existing) {
    $existing | Remove-NetFirewallRule
}

New-NetFirewallRule `
    -DisplayName $TcpRuleName `
    -Group $RuleGroup `
    -Direction Inbound `
    -Action Allow `
    -Enabled True `
    -Profile Private `
    -Protocol TCP `
    -LocalAddress $LanIP `
    -LocalPort 18473,7880,7881 `
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
    -LocalPort 3478,7882,'30000-30019' `
    -RemoteAddress LocalSubnet `
    -EdgeTraversalPolicy Block | Out-Null

Write-Host "OpenIMX Call PoC LAN firewall rules ready for $LanIP (Private + LocalSubnet only; TURN relay UDP 30000-30019 enabled)."
