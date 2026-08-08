param(
    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$DevDir = Join-Path $Root 'infra\dev'
$ComposeFile = Join-Path $DevDir 'compose.yml'
$EnvFile = Join-Path $DevDir '.env'

if (-not (Test-Path -LiteralPath $EnvFile)) {
    throw 'Missing infra\dev\.env. Run .\scripts\init-dev-env.ps1 first.'
}

function Wait-ServiceHealthy {
    param([Parameter(Mandatory = $true)][string]$Service)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $containerId = (& docker compose --env-file $EnvFile -f $ComposeFile ps -q $Service).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to inspect service $Service."
        }
        if ($containerId) {
            $status = (& docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $containerId).Trim()
            if ($status -eq 'healthy') {
                Write-Host "[OK] $Service"
                return
            }
            if ($status -eq 'exited' -or $status -eq 'dead' -or $status -eq 'unhealthy') {
                throw "$Service is $status. Run docker compose logs $Service for details."
            }
        }
        Start-Sleep -Seconds 2
    }
    throw "Timed out waiting for $Service to become healthy."
}

function Assert-Http200 {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Url
    )

    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 5
    if ($response.StatusCode -ne 200) {
        throw "$Name returned HTTP $($response.StatusCode)."
    }
    Write-Host "[OK] $Name -> $Url"
}

Push-Location $DevDir
try {
    foreach ($service in @('postgres', 'redis', 'minio', 'mailpit', 'livekit')) {
        Wait-ServiceHealthy -Service $service
    }

    Assert-Http200 -Name 'MinIO readiness' -Url 'http://127.0.0.1:19000/minio/health/ready'
    Assert-Http200 -Name 'Mailpit readiness' -Url 'http://127.0.0.1:18025/readyz'
    Assert-Http200 -Name 'LiveKit signal' -Url 'http://127.0.0.1:17880/'

    Write-Host ''
    Write-Host 'DEV_INFRA_TEST_PASSED=true'
} finally {
    Pop-Location
}
