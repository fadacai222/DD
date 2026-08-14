param(
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'DD-Server-Wave2.bundle')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$ExpectedCommit = '6ac4e6e6c2d37a234cde3219bb4ce5685a0c5298'
$Branch = 'integrate/2026-08-14-wave2'

Push-Location $Root
try {
    $actual = (& git rev-parse $Branch).Trim()
    if ($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedCommit) {
        throw "Wave2 branch mismatch. Expected $ExpectedCommit, got $actual"
    }

    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force
    }

    & git bundle create $OutputPath "refs/heads/$Branch"
    if ($LASTEXITCODE -ne 0) {
        throw 'git bundle create failed.'
    }

    & git bundle verify $OutputPath | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw 'git bundle verify failed.'
    }

    $item = Get-Item -LiteralPath $OutputPath
    $hash = Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256
    Write-Host ''
    Write-Host 'DD Wave2 production server bundle ready.'
    Write-Host "Commit: $ExpectedCommit"
    Write-Host "File:   $($item.FullName)"
    Write-Host "Size:   $($item.Length) bytes"
    Write-Host "SHA256: $($hash.Hash)"
}
finally {
    Pop-Location
}
