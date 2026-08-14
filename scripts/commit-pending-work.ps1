param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$AdminIntegration = 'C:\Users\admin\.devspace\worktrees\repo-3a3c625c'
$Wave3 = 'C:\Users\admin\.devspace\worktrees\repo-503b2173'
$Wave3Base = '6ac4e6e6c2d37a234cde3219bb4ce5685a0c5298'
$Wave3Branch = 'wave3/2026-08-15-humanfix'

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string[]]$Args,
        [switch]$AllowFailure
    )
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git -C $Repo @Args 2>&1)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
    if (-not $AllowFailure -and $code -ne 0) {
        throw "git -C '$Repo' $($Args -join ' ') failed ($code):`n$($output -join "`n")"
    }
    [pscustomobject]@{ Code = $code; Output = $output }
}

function Assert-RepoExists {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Required worktree is missing: $Path"
    }
    Invoke-Git -Repo $Path -Args @('rev-parse', '--git-dir') | Out-Null
}

function Commit-Paths {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string[]]$Paths
    )
    Invoke-Git -Repo $Repo -Args (@('add', '-A', '--') + $Paths) | Out-Null
    $staged = Invoke-Git -Repo $Repo -Args @('diff', '--cached', '--quiet') -AllowFailure
    if ($staged.Code -eq 0) {
        Write-Host "[skip] no staged changes: $Message"
        return
    }
    Invoke-Git -Repo $Repo -Args @('commit', '-m', $Message) | ForEach-Object { $_.Output | Out-Host }
    Write-Host "[commit] $Message"
}

function Remove-DuplicateAdminMigration {
    $pairs = @(
        @('server/migrations/000034_admin_integrations.up.sql', 'server/migrations/000037_admin_integrations.up.sql'),
        @('server/migrations/000034_admin_integrations.down.sql', 'server/migrations/000037_admin_integrations.down.sql')
    )
    foreach ($pair in $pairs) {
        $oldPath = Join-Path $Root $pair[0]
        $newPath = Join-Path $Root $pair[1]
        if (-not (Test-Path -LiteralPath $oldPath -PathType Leaf)) { continue }
        if (-not (Test-Path -LiteralPath $newPath -PathType Leaf)) {
            throw "Cannot remove duplicate migration because canonical file is missing: $($pair[1])"
        }
        $oldHash = (Get-FileHash -LiteralPath $oldPath -Algorithm SHA256).Hash
        $newHash = (Get-FileHash -LiteralPath $newPath -Algorithm SHA256).Hash
        if ($oldHash -ne $newHash) {
            throw "Migration copies differ; refusing to delete $($pair[0])"
        }
        Remove-Item -LiteralPath $oldPath -Force
        Write-Host "[remove duplicate] $($pair[0])"
    }
}

Assert-RepoExists $Root
Assert-RepoExists $AdminIntegration
Assert-RepoExists $Wave3

Write-Host '=============================================='
Write-Host ' DD Pending Work Commit'
Write-Host '=============================================='
Write-Host ''

# 1. Commit the already-staged Admin-on-Wave2 integration worktree.
$adminHead = ((Invoke-Git -Repo $AdminIntegration -Args @('rev-parse', 'HEAD')).Output -join '').Trim()
if ($adminHead -ne $Wave3Base) {
    $adminBranch = ((Invoke-Git -Repo $AdminIntegration -Args @('branch', '--show-current')).Output -join '').Trim()
    $adminDirty = Invoke-Git -Repo $AdminIntegration -Args @('status', '--porcelain')
    $adminSubjects = @((Invoke-Git -Repo $AdminIntegration -Args @('log', '--format=%s', "$Wave3Base..HEAD")).Output)
    if ($adminBranch -ne 'integrate/2026-08-15-admin' -or
        @($adminDirty.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -ne 0 -or
        -not ($adminSubjects -contains 'feat(admin): configure Telegram sticker relay')) {
        throw "Admin integration HEAD changed unexpectedly: $adminHead ($adminBranch)"
    }
    Write-Host '[skip] Admin-on-Wave2 integration already committed.'
}
else {
    $unstaged = Invoke-Git -Repo $AdminIntegration -Args @('diff', '--quiet') -AllowFailure
    if ($unstaged.Code -ne 0) {
        throw 'Admin integration worktree has unstaged changes; refusing to mix them with the staged integration.'
    }
    $cached = Invoke-Git -Repo $AdminIntegration -Args @('diff', '--cached', '--quiet') -AllowFailure
    if ($cached.Code -eq 0) {
        throw 'Admin integration worktree has nothing staged.'
    }
    Invoke-Git -Repo $AdminIntegration -Args @('commit', '-m', 'feat(admin): integrate Telegram sticker relay on Wave2') | ForEach-Object { $_.Output | Out-Host }
    Write-Host '[commit] Admin Telegram Relay integrated on Wave2.'
}

# 2. Attach Wave3 detached work to a real branch.
$wave3Head = ((Invoke-Git -Repo $Wave3 -Args @('rev-parse', 'HEAD')).Output -join '').Trim()
$wave3CurrentBranch = ((Invoke-Git -Repo $Wave3 -Args @('branch', '--show-current')).Output -join '').Trim()
if ([string]::IsNullOrWhiteSpace($wave3CurrentBranch)) {
    if ($wave3Head -ne $Wave3Base) {
        throw "Detached Wave3 HEAD is not the frozen Wave2 base: $wave3Head"
    }
    $branchExists = Invoke-Git -Repo $Root -Args @('show-ref', '--verify', '--quiet', "refs/heads/$Wave3Branch") -AllowFailure
    if ($branchExists.Code -eq 0) {
        Invoke-Git -Repo $Wave3 -Args @('switch', $Wave3Branch) | Out-Null
    }
    else {
        Invoke-Git -Repo $Wave3 -Args @('switch', '-c', $Wave3Branch) | Out-Null
    }
    Write-Host "[branch] $Wave3Branch"
}
elseif ($wave3CurrentBranch -ne $Wave3Branch) {
    throw "Wave3 worktree is on unexpected branch: $wave3CurrentBranch"
}

$wave3ClientPaths = @(
    'clients/app/android/app/src/main/AndroidManifest.xml',
    'clients/app/ios/Runner/Services/FilePickerService.swift',
    'clients/app/lib/core/notifications/app_notification_service.dart',
    'clients/app/lib/core/notifications/background_android_notification_details.dart',
    'clients/app/lib/features/contacts/presentation/contacts_page.dart',
    'clients/app/lib/features/contacts/presentation/peer_profile_page.dart',
    'clients/app/lib/features/groups/presentation/group_details_page.dart',
    'clients/app/lib/features/messaging/presentation/conversations_page.dart',
    'clients/app/lib/features/messaging/presentation/desktop_mention_profile_dialog.dart',
    'clients/app/lib/features/messaging/presentation/text_chat_page.dart',
    'clients/app/lib/features/push/application/push_notification_content.dart',
    'clients/app/lib/features/push/application/push_registration_service.dart',
    'clients/app/lib/features/shell/presentation/main_shell_page.dart',
    'clients/app/test/core/media/android_large_file_picker_contract_test.dart',
    'clients/app/test/core/notifications/background_android_notification_details_test.dart',
    'clients/app/test/features/contacts/peer_profile_page_test.dart',
    'clients/app/test/features/groups/group_details_page_test.dart',
    'clients/app/test/features/messaging/conversations_page_test.dart',
    'clients/app/test/features/messaging/text_chat_page_test.dart'
)
Commit-Paths -Repo $Wave3 -Message 'feat(client): integrate Wave3 messaging and human-retest fixes' -Paths $wave3ClientPaths

$wave3OpsPaths = @(
    'infra/prod/scripts/deployment-check.sh',
    'infra/prod/scripts/preflight.sh',
    'scripts/build-client.ps1',
    'scripts/generate-brand-assets.ps1'
)
Commit-Paths -Repo $Wave3 -Message 'chore(prod): harden runtime checks and client packaging' -Paths $wave3OpsPaths

# GeneratedPluginRegistrant.java can show a Windows EOL/stat-only M while git diff is empty.
Invoke-Git -Repo $Wave3 -Args @('update-index', '--refresh') -AllowFailure | Out-Null

# 3. Clean duplicate pre-Wave2 migration filenames in main.
Remove-DuplicateAdminMigration

# 4. Commit all remaining main-checkout work in one pass.
# Windows PowerShell 5.1 can corrupt non-ASCII pathspec arguments passed to Git,
# so do not enumerate Chinese filenames here. At this point the main checkout
# has already been reviewed, *.bundle and the known scratch patch are ignored,
# and duplicate 000034 admin migrations were removed above.
$mainUnexpected = @((Invoke-Git -Repo $Root -Args @('status', '--porcelain')).Output | Where-Object {
    $_ -match 'server/migrations/000034_admin_integrations'
})
if ($mainUnexpected.Count -gt 0) {
    throw 'Duplicate 000034 admin migration is still present after cleanup.'
}
Invoke-Git -Repo $Root -Args @('add', '-A') | Out-Null
$mainStaged = Invoke-Git -Repo $Root -Args @('diff', '--cached', '--quiet') -AllowFailure
if ($mainStaged.Code -eq 0) {
    Write-Host '[skip] no remaining main-checkout changes to commit.'
}
else {
    Invoke-Git -Repo $Root -Args @('commit', '-m', 'chore(repo): record Wave3 evidence and operator helpers') | ForEach-Object { $_.Output | Out-Host }
    Write-Host '[commit] main Wave3 evidence and operator helpers'
}

Write-Host ''
Write-Host '=============================================='
Write-Host ' Commit result'
Write-Host '=============================================='
Write-Host 'Main:'
& git -C $Root log -3 --oneline
Write-Host ''
Write-Host 'Admin integration:'
& git -C $AdminIntegration log -2 --oneline
Write-Host ''
Write-Host 'Wave3:'
& git -C $Wave3 log -3 --oneline
Write-Host ''
Write-Host 'Remaining status:'
Write-Host '[main]'
& git -C $Root status --short --branch
Write-Host '[admin integration]'
& git -C $AdminIntegration status --short --branch
Write-Host '[wave3]'
& git -C $Wave3 status --short --branch
