$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$MigrateScript = Join-Path $PSScriptRoot 'invoke-dev-migrate.ps1'

Write-Host '[1/4] Apply pending migrations'
& $MigrateScript -Action up

Write-Host '[2/4] Verify idempotent second up'
& $MigrateScript -Action up

Write-Host '[3/4] Roll back one migration'
& $MigrateScript -Action down

Write-Host '[4/4] Re-apply rollback'
& $MigrateScript -Action up

Write-Host 'MIGRATION_ROUNDTRIP_TEST_PASSED=true'
