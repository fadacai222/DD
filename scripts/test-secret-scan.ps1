$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Image = 'ghcr.io/gitleaks/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f'

function Assert-DockerAvailable {
    $null = Get-Command docker -ErrorAction Stop
    & docker version --format '{{.Server.Version}}' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker is required for the pinned Gitleaks secret scan.'
    }
}

function Invoke-RepositorySecretScan {
    Write-Host '[secret-scan] scanning full Git history with pinned Gitleaks...'
    $Mount = "${Root}:/repo:ro"
    & docker run --rm `
        --volume $Mount `
        --workdir /repo `
        $Image `
        git `
        --config /repo/.gitleaks.toml `
        --redact `
        --no-banner `
        --no-color `
        --max-archive-depth 2 `
        --max-decode-depth 2 `
        /repo
    if ($LASTEXITCODE -ne 0) {
        throw "Gitleaks repository scan failed with exit code $LASTEXITCODE."
    }
}

function Assert-DetectorRejectsKnownLeak {
    $FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dd-gitleaks-selftest-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $FixtureRoot -Force | Out-Null
    try {
        # Build the token at runtime so this script itself never contains a
        # complete credential-shaped fixture that needs an allowlist. Put it
        # under the Firebase client-config path on purpose: if that allowlist
        # is ever broadened from one field/rule to the whole path, this self-
        # test must start failing.
        $FakeToken = 'ghp_' + [Guid]::NewGuid().ToString('N') + 'AbCd'
        $FixtureFile = Join-Path $FixtureRoot 'clients/app/android/app/google-services.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $FixtureFile) -Force | Out-Null
        Set-Content -LiteralPath $FixtureFile -Value ("{`"unexpected_secret`":`"$FakeToken`"}") -Encoding utf8

        Write-Host '[secret-scan] verifying the detector blocks an injected credential inside an allowlisted path...'
        $FixtureMount = "${FixtureRoot}:/fixture:ro"
        $RepoMount = "${Root}:/repo:ro"
        & docker run --rm `
            --volume $FixtureMount `
            --volume $RepoMount `
            $Image `
            dir `
            --config /repo/.gitleaks.toml `
            --redact `
            --no-banner `
            --no-color `
            /fixture
        $ExitCode = $LASTEXITCODE
        if ($ExitCode -eq 0) {
            throw 'Gitleaks self-test failed: an injected credential was not detected.'
        }
        if ($ExitCode -ne 1) {
            throw "Gitleaks self-test failed unexpectedly with exit code $ExitCode."
        }
    }
    finally {
        Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Assert-DockerAvailable
Invoke-RepositorySecretScan
Assert-DetectorRejectsKnownLeak
Write-Host '[secret-scan] PASS'
