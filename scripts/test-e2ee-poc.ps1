param(
    [switch]$SkipCrossCompile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$CryptoDir = Join-Path $Root 'crypto\e2ee_poc'

foreach ($command in @('cargo', 'rustup')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command is required for the E2EE PoC checks."
    }
}

Push-Location $CryptoDir
try {
    & cargo fmt --check
    if ($LASTEXITCODE -ne 0) { throw 'cargo fmt --check failed.' }

    & cargo clippy --all-targets -- -D warnings
    if ($LASTEXITCODE -ne 0) { throw 'cargo clippy failed.' }

    & cargo test
    if ($LASTEXITCODE -ne 0) { throw 'native E2EE PoC tests failed.' }

    if (-not $SkipCrossCompile) {
        $targets = @(
            'wasm32-unknown-unknown',
            'aarch64-linux-android',
            'aarch64-apple-ios',
            'aarch64-apple-darwin',
            'x86_64-unknown-linux-gnu'
        )
        & rustup target add @targets
        if ($LASTEXITCODE -ne 0) { throw 'failed to install required Rust targets.' }

        & cargo check --target wasm32-unknown-unknown --features vodozemac/js
        if ($LASTEXITCODE -ne 0) { throw 'WASM E2EE PoC compile check failed.' }

        foreach ($target in $targets | Where-Object { $_ -ne 'wasm32-unknown-unknown' }) {
            & cargo check --target $target
            if ($LASTEXITCODE -ne 0) { throw "E2EE PoC compile check failed for $target." }
        }
    }
} finally {
    Pop-Location
}

Write-Host 'E2EE_POC_TEST_PASSED=true'
