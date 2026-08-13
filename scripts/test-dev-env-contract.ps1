$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$SourceScript = Join-Path $PSScriptRoot 'init-dev-env.ps1'
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dd-dev-env-contract-" + [guid]::NewGuid().ToString('N'))

function Get-SettingValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $matches = @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_ -match "^\s*$([regex]::Escape($Name))=" })
    if ($matches.Count -ne 1) {
        throw "$Name must appear exactly once in $Path; found $($matches.Count)."
    }
    return ($matches[0] -split '=', 2)[1].Trim()
}

function New-TestLayout {
    param([Parameter(Mandatory = $true)][string]$Name)

    $root = Join-Path $TempRoot $Name
    $scripts = Join-Path $root 'scripts'
    $dev = Join-Path $root 'infra\dev'
    New-Item -ItemType Directory -Path $scripts, $dev -Force | Out-Null
    Copy-Item -LiteralPath $SourceScript -Destination (Join-Path $scripts 'init-dev-env.ps1')
    return $root
}

try {
    $upgradeRoot = New-TestLayout -Name 'upgrade'
    $upgradeEnv = Join-Path $upgradeRoot 'infra\dev\.env'
    [System.IO.File]::WriteAllText(
        $upgradeEnv,
        "DD_POSTGRES_DB=dd`nAUTH_TOKEN_SECRET=preserve-this-auth-secret`nEMAIL_CODE_PEPPER=preserve-this-email-pepper`n",
        [System.Text.UTF8Encoding]::new($false)
    )

    & (Join-Path $upgradeRoot 'scripts\init-dev-env.ps1')
    $firstAdminSecret = Get-SettingValue -Path $upgradeEnv -Name 'ADMIN_SECURITY_SECRET'
    if ($firstAdminSecret.Length -lt 32) {
        throw "Upgraded ADMIN_SECURITY_SECRET is too short: $($firstAdminSecret.Length)."
    }
    if ((Get-SettingValue -Path $upgradeEnv -Name 'AUTH_TOKEN_SECRET') -ne 'preserve-this-auth-secret') {
        throw 'Existing AUTH_TOKEN_SECRET was changed during in-place upgrade.'
    }

    & (Join-Path $upgradeRoot 'scripts\init-dev-env.ps1')
    $secondAdminSecret = Get-SettingValue -Path $upgradeEnv -Name 'ADMIN_SECURITY_SECRET'
    if ($secondAdminSecret -ne $firstAdminSecret) {
        throw 'Existing ADMIN_SECURITY_SECRET was rotated during a non-Force rerun.'
    }

    $blankRoot = New-TestLayout -Name 'blank-required-secret'
    $blankEnv = Join-Path $blankRoot 'infra\dev\.env'
    [System.IO.File]::WriteAllText(
        $blankEnv,
        "AUTH_TOKEN_SECRET=preserve-this-auth-secret`nADMIN_SECURITY_SECRET=`nEMAIL_CODE_PEPPER=preserve-this-email-pepper`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    & (Join-Path $blankRoot 'scripts\init-dev-env.ps1')
    $repairedAdminSecret = Get-SettingValue -Path $blankEnv -Name 'ADMIN_SECURITY_SECRET'
    if ($repairedAdminSecret.Length -lt 32) {
        throw "Blank ADMIN_SECURITY_SECRET was not repaired: $($repairedAdminSecret.Length)."
    }

    $freshRoot = New-TestLayout -Name 'fresh'
    $freshEnv = Join-Path $freshRoot 'infra\dev\.env'
    & (Join-Path $freshRoot 'scripts\init-dev-env.ps1')
    $freshAdminSecret = Get-SettingValue -Path $freshEnv -Name 'ADMIN_SECURITY_SECRET'
    if ($freshAdminSecret.Length -lt 32) {
        throw "Fresh ADMIN_SECURITY_SECRET is too short: $($freshAdminSecret.Length)."
    }

    Write-Host 'DEV_ENV_CONTRACT_PASSED=true'
}
finally {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
