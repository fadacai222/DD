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

function Test-FirewallRuleReady {
    param(
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$Protocol,
        [Parameter(Mandatory = $true)][string[]]$LocalPorts
    )

    $rule = Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $rule) { return $false }
    if ($rule.Enabled -ne 'True' -or $rule.Direction -ne 'Inbound' -or $rule.Action -ne 'Allow' -or $rule.Profile -ne 'Private') {
        return $false
    }

    $portFilter = $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
    $addressFilter = $rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
    if ($null -eq $portFilter -or $null -eq $addressFilter) { return $false }
    if ([string]$portFilter.Protocol -ne $Protocol) { return $false }

    $actualPorts = @($portFilter.LocalPort | ForEach-Object { [string]$_ } | Sort-Object)
    $expectedPorts = @($LocalPorts | ForEach-Object { [string]$_ } | Sort-Object)
    if (($actualPorts -join ',') -ne ($expectedPorts -join ',')) { return $false }
    if ((@($addressFilter.LocalAddress) -join ',') -ne $LanIP) { return $false }
    if ((@($addressFilter.RemoteAddress) -join ',') -ne 'LocalSubnet') { return $false }
    return $true
}

if (-not $Remove) {
    $tcpReady = Test-FirewallRuleReady -DisplayName $RuleName -Protocol 'TCP' -LocalPorts @('18473', '17880', '17881', '19000')
    $udpReady = Test-FirewallRuleReady -DisplayName $UdpRuleName -Protocol 'UDP' -LocalPorts @('17882', '13478')
    if ($tcpReady -and $udpReady) {
        Write-Host "DD Auth Dev firewall already ready for $LanIP; elevation skipped."
        exit 0
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
