param([switch]$SkipBuilds)

$ErrorActionPreference = 'Stop'
$env:GIT_EDITOR = 'true'

# Keep this script ASCII-only so Windows PowerShell 5.1 does not reinterpret
# UTF-8-without-BOM source text using the active ANSI code page.
$Base = '12a858a41d14190736f8b3fc09cd44f1c691acc8'
$Ai05 = 'C:\Users\admin\.devspace\worktrees\repo-dcc1053e'
$Integration = 'C:\Users\admin\.devspace\worktrees\repo-7f74fe49'
$IntegrationBranch = 'integrate/2026-08-14-wave1'
$Ai05CoreSubject = 'fix(stickers): make Telegram import failures visible and actionable'
$Ai05SharedSubject = 'fix(stickers): align shared pack import errors'

function Invoke-Git {
    param([Parameter(Mandatory=$true)][string[]]$GitArgs)
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') failed"
    }
}

function Get-CommitByExactSubject {
    param([Parameter(Mandatory=$true)][string]$Subject)
    $hash = (& git log --format='%H%x09%s' -n 30 | Where-Object {
        $parts = $_ -split "`t", 2
        $parts.Count -eq 2 -and $parts[1] -eq $Subject
    } | Select-Object -First 1)
    if (-not $hash) { return $null }
    return (($hash -split "`t", 2)[0]).Trim()
}

function Test-SubjectAlreadyIntegrated {
    param([Parameter(Mandatory=$true)][string]$Commit)
    $subject = (& git show -s --format='%s' $Commit).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Cannot read commit subject for $Commit" }
    $subjects = @(& git log --format='%s' "$Base..HEAD")
    return ($subjects -contains $subject)
}

Write-Host '[1/4] Commit AI05 explicitly'
Set-Location $Ai05
Invoke-Git -GitArgs @('restore', '--staged', '--worktree', '--', 'clients/app/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java')

$core = @(
    'clients/app/lib/features/messaging/data/sticker_api_client.dart',
    'clients/app/lib/features/messaging/presentation/sticker_library_sheet.dart',
    'clients/app/lib/features/messaging/presentation/sticker_operation_error_text.dart',
    'clients/app/test/features/messaging/sticker_api_client_test.dart',
    'clients/app/test/features/messaging/sticker_library_sheet_test.dart',
    'server/internal/httpapi/stickers.go',
    'server/internal/httpapi/stickers_test.go',
    'server/internal/stickers/models.go',
    'server/internal/stickers/service.go',
    'server/internal/stickers/telegram_provider.go',
    'server/internal/stickers/telegram_provider_test.go'
)

$Ai05Core = Get-CommitByExactSubject -Subject $Ai05CoreSubject
$coreStatus = @(& git status --porcelain -- $core)
if ($coreStatus.Count -gt 0) {
    $addCore = @('add', '--') + $core
    Invoke-Git -GitArgs $addCore
    Invoke-Git -GitArgs @('commit', '-m', $Ai05CoreSubject)
    $Ai05Core = (& git rev-parse HEAD).Trim()
} elseif (-not $Ai05Core) {
    throw 'AI05 core has no pending changes and no matching commit was found.'
}

$shared = @(
    'clients/app/lib/features/messaging/presentation/text_chat_page.dart',
    'clients/app/test/features/messaging/text_chat_page_test.dart',
    'tasks/2026-08-14-bugfix/reports/AI05.md'
)

$Ai05Shared = Get-CommitByExactSubject -Subject $Ai05SharedSubject
$sharedStatus = @(& git status --porcelain -- $shared)
if ($sharedStatus.Count -gt 0) {
    $addShared = @('add', '--') + $shared
    Invoke-Git -GitArgs $addShared
    Invoke-Git -GitArgs @('commit', '-m', $Ai05SharedSubject)
    $Ai05Shared = (& git rev-parse HEAD).Trim()
} elseif (-not $Ai05Shared) {
    throw 'AI05 shared UI has no pending changes and no matching commit was found.'
}

# Coordinator owns shared docs. Do not let AI05 documentation changes or a
# Windows line-ending-only generated registrant block the isolated commits.
Invoke-Git -GitArgs @('restore', '--staged', '--worktree', '--', 'docs/README.md', ':(glob)docs/15-*.md', 'clients/app/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java')
if (@(& git status --porcelain).Count -ne 0) {
    & git status --short
    throw 'AI05 worktree still has unexpected changes after explicit commits.'
}

Write-Host '[2/4] Build Wave1 integration branch'
Set-Location $Integration
# Flutter tooling can touch this generated Java file only through line-ending/stat
# normalization. Restore it before cleanliness checks so a content-identical fake
# modification never blocks a rerun.
Invoke-Git -GitArgs @('restore', '--staged', '--worktree', '--', 'clients/app/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java', ':(glob)**/brand-assets/DD-icon-1024.png')
if (@(& git status --porcelain).Count -ne 0) { throw 'Integration worktree is not clean.' }

$currentBranch = (@(& git branch --show-current) -join '').Trim()
$currentHead = (@(& git rev-parse HEAD) -join '').Trim()
if ($currentBranch -eq '') {
    if ($currentHead -ne $Base) {
        throw "Detached integration worktree is at $currentHead instead of expected base $Base."
    }
    & git show-ref --verify --quiet "refs/heads/$IntegrationBranch"
    if ($LASTEXITCODE -eq 0) {
        Invoke-Git -GitArgs @('switch', $IntegrationBranch)
    } else {
        Invoke-Git -GitArgs @('switch', '-c', $IntegrationBranch)
    }
} elseif ($currentBranch -ne $IntegrationBranch) {
    throw "Integration worktree is on unexpected branch $currentBranch."
}

$commits = @(
    '715ff5b1370ea3a452d065991f8f1fdcba2cf12c',
    'f54578ae095bc85db76949ef059c9fddec04652d',
    '637f4f6c1898e83cc57f4f7240fb5826f6dbf90b',
    'dc27ba01f01cf580fddaeb6af5ba926dafd4f3e7',
    '326e9025b2f6cca53ad170138b28797d34b1b53a',
    $Ai05Core,
    $Ai05Shared,
    '695f93ebec4720783d2b7b7b782e7f38c9ec4675'
)

foreach ($commit in $commits) {
    if (Test-SubjectAlreadyIntegrated -Commit $commit) {
        Write-Host "skip already integrated: $commit"
        continue
    }

    & git cherry-pick $commit
    if ($LASTEXITCODE -eq 0) { continue }

    $conflicts = @(& git diff --name-only --diff-filter=U)
    $unexpected = @($conflicts | Where-Object {
        $_ -ne 'docs/README.md' -and $_ -notlike 'docs/15-*'
    })
    if ($conflicts.Count -eq 0 -or $unexpected.Count -gt 0) {
        & git cherry-pick --abort
        throw "Unexpected conflict while cherry-picking $commit : $($conflicts -join ', ')"
    }

    if ($conflicts -contains 'docs/README.md') {
        Invoke-Git -GitArgs @('checkout', '--ours', '--', 'docs/README.md')
        Invoke-Git -GitArgs @('add', '--', 'docs/README.md')
    }
    if (@($conflicts | Where-Object { $_ -like 'docs/15-*' }).Count -gt 0) {
        Invoke-Git -GitArgs @('checkout', '--ours', '--', ':(glob)docs/15-*.md')
        Invoke-Git -GitArgs @('add', '--', ':(glob)docs/15-*.md')
    }
    Invoke-Git -GitArgs @('cherry-pick', '--continue')
}

Write-Host '[3/4] Run full gates'
Set-Location (Join-Path $Integration 'server')
& go test ./...
if ($LASTEXITCODE -ne 0) { throw 'go test ./... failed' }
& go vet ./...
if ($LASTEXITCODE -ne 0) { throw 'go vet ./... failed' }

Set-Location (Join-Path $Integration 'clients\realtime_poc')
& flutter test
if ($LASTEXITCODE -ne 0) { throw 'realtime_poc flutter test failed' }

Set-Location (Join-Path $Integration 'clients\app')
# A fresh Git worktree has no .dart_tool/package_config.json. Resolve Flutter
# packages before invoking the standalone Dart analyzer, otherwise package:flutter
# is unresolved and the analyzer emits tens of thousands of cascading errors.
& flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'clients/app flutter pub get failed' }
& dart analyze --fatal-infos
if ($LASTEXITCODE -ne 0) { throw 'dart analyze failed' }
& flutter test
if ($LASTEXITCODE -ne 0) { throw 'flutter test failed' }

if (-not $SkipBuilds) {
    Set-Location $Integration
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\scripts\build-client.ps1' -Target windows-android
    if ($LASTEXITCODE -ne 0) { throw 'Windows/Android build smoke failed' }

    # AI03 changed the canonical 1024 icon generator from inset 0.86 to full-bleed
    # 1.00. The tracked generated PNG must move with that source change; otherwise
    # every future build dirties the repository again.
    $brandIconStatus = @(& git status --porcelain -- ':(glob)**/brand-assets/DD-icon-1024.png')
    if ($brandIconStatus.Count -gt 0) {
        Invoke-Git -GitArgs @('add', '--', ':(glob)**/brand-assets/DD-icon-1024.png')
        Invoke-Git -GitArgs @('commit', '-m', 'chore(brand): regenerate full-bleed app icon')
    }
}

Write-Host '[4/4] Wave1 checkpoint ready'
Set-Location $Integration
Invoke-Git -GitArgs @('restore', '--staged', '--worktree', '--', 'clients/app/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java')
Invoke-Git -GitArgs @('diff', '--check', $Base, 'HEAD')
if (@(& git status --porcelain).Count -ne 0) {
    & git status --short
    throw 'Integration worktree is unexpectedly dirty after Wave1 gates.'
}
$Checkpoint = (& git rev-parse HEAD).Trim()
Write-Host "WAVE2_BASE_COMMIT=$Checkpoint"
Write-Host "AI05_CORE=$Ai05Core"
Write-Host "AI05_SHARED=$Ai05Shared"
Write-Host 'No merge into dirty master was performed; continue Wave2 from the checkpoint above.'
