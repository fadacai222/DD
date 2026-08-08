param(
    [string]$LanIP
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$BaseCompose = Join-Path $Root 'compose.call-poc.yml'
$LanCompose = Join-Path $Root 'compose.call-poc.lan.yml'
$FirewallScript = Join-Path $PSScriptRoot 'configure-call-poc-lan-firewall.ps1'
$StateDir = Join-Path $Root '.data'
$StateFile = Join-Path $StateDir 'call-poc-lan.json'
$RestoreMarker = Join-Path $StateDir 'restore-realtime-after-call-poc.flag'
$StoppedRealtime = $false

function Test-PrivateIPv4 {
    param([Parameter(Mandatory = $true)][string]$Address)

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) {
        return $false
    }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return $false
    }

    $bytes = $parsed.GetAddressBytes()
    if ($bytes[0] -eq 10) { return $true }
    if ($bytes[0] -eq 192 -and $bytes[1] -eq 168) { return $true }
    if ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) { return $true }
    return $false
}

function Get-PreferredLanIP {
    $candidates = @()
    foreach ($configuration in Get-NetIPConfiguration) {
        if ($null -eq $configuration.IPv4DefaultGateway) { continue }
        if ($null -eq $configuration.NetAdapter -or $configuration.NetAdapter.Status -ne 'Up') { continue }

        foreach ($address in @($configuration.IPv4Address)) {
            if ($null -eq $address) { continue }
            $ip = [string]$address.IPAddress
            if (-not (Test-PrivateIPv4 -Address $ip)) { continue }

            $metric = (Get-NetIPInterface -InterfaceIndex $configuration.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
            if ($null -eq $metric) { $metric = 9999 }
            $candidates += [pscustomobject]@{
                IP = $ip
                InterfaceAlias = $configuration.InterfaceAlias
                Metric = [int]$metric
            }
        }
    }

    $preferred = $candidates | Sort-Object Metric, InterfaceAlias | Select-Object -First 1
    if ($null -eq $preferred) {
        throw 'No active private IPv4 interface with a default gateway was found. Supply -LanIP explicitly.'
    }
    return $preferred
}

function Assert-LocalLanIP {
    param([Parameter(Mandatory = $true)][string]$Address)

    if (-not (Test-PrivateIPv4 -Address $Address)) {
        throw "LAN IP must be a private IPv4 address, got: $Address"
    }
    $local = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $Address -ErrorAction SilentlyContinue
    if ($null -eq $local) {
        throw "LAN IP $Address is not assigned to this computer."
    }
}

function Wait-HttpOK {
    param([Parameter(Mandatory = $true)][string]$Url)

    foreach ($attempt in 1..40) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 2
            if ($response.StatusCode -eq 200) { return }
        }
        catch {
            Start-Sleep -Milliseconds 250
        }
    }
    throw "Timed out waiting for $Url"
}

& docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'Docker Desktop is not running. Start it and rerun this script.'
}

if ([string]::IsNullOrWhiteSpace($LanIP)) {
    $selected = Get-PreferredLanIP
    $LanIP = $selected.IP
    Write-Host "Detected LAN interface: $($selected.InterfaceAlias) -> $LanIP"
}
else {
    $LanIP = $LanIP.Trim()
}
Assert-LocalLanIP -Address $LanIP

& $FirewallScript -LanIP $LanIP
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to configure the LAN firewall rules.'
}

New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
$env:IM_LAN_IP = $LanIP

Push-Location $Root
try {
    $runningName = & docker ps --filter 'name=selfhosted-im-poc-realtime-api-1' --format '{{.Names}}'
    if ($runningName -contains 'selfhosted-im-poc-realtime-api-1') {
        & docker compose -f compose.poc.yml down --remove-orphans
        if ($LASTEXITCODE -ne 0) { throw 'Existing realtime PoC failed to stop.' }
        $StoppedRealtime = $true
        Set-Content -LiteralPath $RestoreMarker -Value 'restore' -Encoding ASCII
    }

    & docker compose -f $BaseCompose -f $LanCompose up -d --build --force-recreate
    if ($LASTEXITCODE -ne 0) { throw 'LAN Call PoC services failed to start.' }

    Wait-HttpOK "http://$LanIP`:18473/health"
    Wait-HttpOK "http://$LanIP`:7880/"

    $liveKitContainerID = (& docker compose -f $BaseCompose -f $LanCompose ps -q livekit).Trim()
    if ([string]::IsNullOrWhiteSpace($liveKitContainerID)) {
        throw 'Unable to resolve the LiveKit container ID after startup.'
    }
    $liveKitEnvironment = (& docker inspect $liveKitContainerID --format '{{range .Config.Env}}{{println .}}{{end}}') -join "`n"
    $requiredPeerCIDR = "$LanIP/32"
    if ($liveKitEnvironment -notmatch ('allow_restricted_peer_cidrs:[\s\S]*' + [regex]::Escape($requiredPeerCIDR))) {
        throw "LiveKit TURN private-peer permission is missing for $requiredPeerCIDR."
    }

    $logs = & docker compose -f $BaseCompose -f $LanCompose logs --no-color --tail 80 livekit
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read LiveKit startup logs.' }
    $joinedLogs = $logs -join "`n"
    if ($joinedLogs -notmatch ('"nodeIP":\s*"' + [regex]::Escape($LanIP) + '"')) {
        throw "LiveKit did not advertise the expected LAN node IP $LanIP."
    }
    if ($joinedLogs -notmatch '"turn\.relay_range_start":\s*30000' -or $joinedLogs -notmatch '"turn\.relay_range_end":\s*30019') {
        throw 'LiveKit TURN relay allocation range is not 30000-30019; relay-only diagnostics would be unreliable.'
    }

    [pscustomobject]@{
        lanIP = $LanIP
        apiUrl = "http://$LanIP`:18473"
        liveKitUrl = "ws://$LanIP`:7880"
        turnRelayRange = '30000-30019/udp'
        startedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8

    Write-Host ''
    Write-Host 'LAN Call PoC is ready for Android testing.'
    Write-Host "  Android service address: http://$LanIP`:18473"
    Write-Host "  LiveKit:               ws://$LanIP`:7880"
    Write-Host "  RTC TCP:               $LanIP`:7881"
    Write-Host "  RTC UDP:               $LanIP`:7882/udp"
    Write-Host "  TURN UDP:              $LanIP`:3478/udp"
    Write-Host "  TURN relay UDP:        $LanIP`:30000-30019/udp"
    Write-Host '  Firewall scope:         Private profile + LocalSubnet only'
    Write-Host ''
    Write-Host 'Phone and PC must be on the same LAN. Do not use 127.0.0.1 on Android.'
    Write-Host 'Stop: powershell -ExecutionPolicy Bypass -File .\scripts\stop-call-poc-lan.ps1'
}
catch {
    $OriginalError = $_
    $PreviousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        & docker compose -f $BaseCompose -f $LanCompose down --remove-orphans *> $null
        if ($StoppedRealtime) {
            & docker compose -f compose.poc.yml up -d --build *> $null
            if ($LASTEXITCODE -eq 0) {
                Remove-Item -LiteralPath $RestoreMarker -Force -ErrorAction SilentlyContinue
            }
            else {
                Write-Warning 'LAN PoC startup failed, and restoring the previous realtime PoC also failed. The original startup error is preserved below.'
            }
        }
        Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    }
    finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }
    throw $OriginalError
}
finally {
    Remove-Item Env:IM_LAN_IP -ErrorAction SilentlyContinue
    Pop-Location
}
