$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$LkExe = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\LiveKit.LiveKitCLI_Microsoft.Winget.Source_8wekyb3d8bbwe\lk.exe'
$RoomName = 'p0-call-media'
$PublisherIdentity = 'media-smoke'
$PublisherProcess = $null
$StdoutLog = Join-Path $env:TEMP ("openimx-livekit-{0}.out.log" -f [guid]::NewGuid().ToString('N'))
$StderrLog = Join-Path $env:TEMP ("openimx-livekit-{0}.err.log" -f [guid]::NewGuid().ToString('N'))
$PreviousRealtimeRunning = $false

function Invoke-DockerCompose {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    & docker compose @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose failed: $($Arguments -join ' ')"
    }
}

function Wait-HttpOK {
    param([Parameter(Mandatory = $true)][string]$Url)
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 2
            if ($response.StatusCode -eq 200) { return }
        }
        catch {
            Start-Sleep -Seconds 1
        }
    }
    throw "Timed out waiting for $Url"
}

function Get-NumberProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names
    )
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property) {
            return [int]$property.Value
        }
    }
    return 0
}

if (-not (Test-Path -LiteralPath $LkExe)) {
    throw "LiveKit CLI not found: $LkExe"
}
& docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'Docker Desktop is not running.'
}

Push-Location $Root
try {
    $runningName = & docker ps --filter 'name=selfhosted-im-poc-realtime-api-1' --format '{{.Names}}'
    $PreviousRealtimeRunning = $runningName -contains 'selfhosted-im-poc-realtime-api-1'
    if ($PreviousRealtimeRunning) {
        Invoke-DockerCompose @('-f', 'compose.poc.yml', 'down', '--remove-orphans')
    }

    Invoke-DockerCompose @('-f', 'compose.call-poc.yml', 'up', '-d', '--build')
    Wait-HttpOK 'http://127.0.0.1:18473/health'
    Wait-HttpOK 'http://127.0.0.1:7880/'

    $liveKitContainerID = (& docker compose -f compose.call-poc.yml ps -q livekit).Trim()
    if ([string]::IsNullOrWhiteSpace($liveKitContainerID)) {
        throw 'Unable to resolve the LiveKit container ID.'
    }
    $liveKitEnvironment = (& docker inspect $liveKitContainerID --format '{{range .Config.Env}}{{println .}}{{end}}') -join "`n"
    if ($liveKitEnvironment -notmatch 'allow_restricted_peer_cidrs:[\s\S]*127\.0\.0\.1/32') {
        throw 'LiveKit TURN is not allowed to relay to the local SFU private peer 127.0.0.1/32.'
    }
    Write-Host 'TURN_PRIVATE_PEER_PERMISSION_TEST_PASSED=true'

    $liveKitLogs = (& docker compose -f compose.call-poc.yml logs --no-color livekit) -join "`n"
    if ($liveKitLogs -notmatch '"nodeIP":\s*"127\.0\.0\.1"') {
        throw 'LiveKit is not advertising 127.0.0.1 for the local PoC; browser ICE may receive an unreachable Docker address.'
    }
    if ($liveKitLogs -notmatch '"turn\.relay_range_start":\s*30000' -or $liveKitLogs -notmatch '"turn\.relay_range_end":\s*30019') {
        throw 'LiveKit TURN relay range is not configured as 30000-30019.'
    }
    Write-Host 'LIVEKIT_LOCAL_NODE_IP_TEST_PASSED=true'
    Write-Host 'TURN_RELAY_RANGE_TEST_PASSED=true'

    $tokenBody = @{
        room_name = $RoomName
        participant_identity = 'token-smoke'
        participant_name = 'Token Smoke'
    } | ConvertTo-Json -Compress
    $tokenResponse = Invoke-RestMethod `
        -Method Post `
        -Uri 'http://127.0.0.1:18473/api/calls/token' `
        -ContentType 'application/json' `
        -Body $tokenBody
    if (-not $tokenResponse.participant_token -or $tokenResponse.server_url -ne 'ws://127.0.0.1:7880') {
        throw 'Token endpoint returned an invalid response.'
    }
    Write-Host 'TOKEN_TEST_PASSED=true'

    $PublisherProcess = Start-Process `
        -FilePath $LkExe `
        -ArgumentList @(
            'room', 'join',
            '--identity', $PublisherIdentity,
            '--url', 'ws://127.0.0.1:7880',
            '--api-key', 'devkey',
            '--api-secret', 'secret',
            '--publish-demo',
            $RoomName
        ) `
        -RedirectStandardOutput $StdoutLog `
        -RedirectStandardError $StderrLog `
        -WindowStyle Hidden `
        -PassThru
    Write-Host ("PUBLISHER_PID={0}" -f $PublisherProcess.Id)

    $mediaPublished = $false
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        Start-Sleep -Seconds 1
        if ($PublisherProcess.HasExited) {
            $stderr = if (Test-Path $StderrLog) { Get-Content -Raw -LiteralPath $StderrLog } else { '' }
            throw "LiveKit publisher exited early. $stderr"
        }

        $roomJson = & $LkExe room list --json `
            --url 'ws://127.0.0.1:7880' `
            --api-key 'devkey' `
            --api-secret 'secret'
        if ($LASTEXITCODE -ne 0) { continue }
        $decodedRooms = $roomJson | ConvertFrom-Json
        $roomsProperty = $decodedRooms.PSObject.Properties['rooms']
        $rooms = if ($null -ne $roomsProperty) {
            @($roomsProperty.Value)
        }
        else {
            @($decodedRooms)
        }
        $room = $rooms | Where-Object {
            $nameProperty = $_.PSObject.Properties['name']
            $null -ne $nameProperty -and $nameProperty.Value -eq $RoomName
        } | Select-Object -First 1
        if ($null -eq $room) { continue }

        $participants = Get-NumberProperty $room @('numParticipants', 'num_participants', 'NumParticipants')
        $publishers = Get-NumberProperty $room @('numPublishers', 'num_publishers', 'NumPublishers')
        if ($participants -ge 1 -and $publishers -ge 1) {
            $mediaPublished = $true
            Write-Host ("MEDIA_ROOM participants={0} publishers={1}" -f $participants, $publishers)
            break
        }
    }

    if (-not $mediaPublished) {
        $stderr = if (Test-Path $StderrLog) { Get-Content -Raw -LiteralPath $StderrLog } else { '' }
        throw "Demo media was not published before timeout. $stderr"
    }
    Write-Host 'LIVEKIT_MEDIA_TEST_PASSED=true'

    $liveKitLogs = & docker compose -f compose.call-poc.yml logs --no-color --tail 500 livekit
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect LiveKit logs for TURN relay candidates.'
    }
    if (($liveKitLogs -join "`n") -notmatch 'udp relay ') {
        throw 'TURN is enabled but no UDP relay candidate was observed.'
    }
    Write-Host 'TURN_RELAY_CANDIDATE_TEST_PASSED=true'
}
finally {
    if ($null -ne $PublisherProcess -and -not $PublisherProcess.HasExited) {
        Stop-Process -Id $PublisherProcess.Id -Force -ErrorAction SilentlyContinue
        $PublisherProcess.WaitForExit()
    }

    Invoke-DockerCompose @('-f', 'compose.call-poc.yml', 'down', '--remove-orphans')
    if ($PreviousRealtimeRunning) {
        Invoke-DockerCompose @('-f', 'compose.poc.yml', 'up', '-d', '--build')
    }

    Remove-Item -LiteralPath $StdoutLog, $StderrLog -Force -ErrorAction SilentlyContinue
    Pop-Location
}

Write-Host 'CALL_POC_CLEANUP_COMPLETE=true'
