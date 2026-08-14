param(
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$KeepWave3 = 'C:\Users\admin\.devspace\worktrees\repo-503b2173'
$ArchiveRoot = Join-Path 'C:\Users\admin\.devspace\worktree-archive' (Get-Date -Format 'yyyyMMdd-HHmmss')

$Disposable = [ordered]@{
    'repo-0bb05e25' = '637f4f6c1898e83cc57f4f7240fb5826f6dbf90b'
    'repo-0ccd5cae' = '5cb98d97c75a62402d1bc1097f6ba391a19efaef'
    'repo-1f613ee2' = 'b0d3cb434e7aadd75148feba391a25342203f027'
    'repo-2358dc5c' = '360ac7f89f4bc565a8badf6055727dfd13c003cb'
    'repo-2560e781' = '3b00b1ab0ac548286be125ab847b06c9ffe94089'
    'repo-322bafc2' = '6ac4e6e6c2d37a234cde3219bb4ce5685a0c5298'
    'repo-335cf2a7' = 'dc27ba01f01cf580fddaeb6af5ba926dafd4f3e7'
    'repo-44b23ff1' = 'f54578ae095bc85db76949ef059c9fddec04652d'
    'repo-56e5bbfb' = '326e9025b2f6cca53ad170138b28797d34b1b53a'
    'repo-6e26827b' = '715ff5b1370ea3a452d065991f8f1fdcba2cf12c'
    'repo-7f74fe49' = 'b601d98317fb3478d3c84227a4ee9dac76d0ae17'
    'repo-d1b35e04' = '6ac4e6e6c2d37a234cde3219bb4ce5685a0c5298'
    'repo-d413b5d5' = '74a308331d9c55adc14155be69d8753336956712'
    'repo-d76aecd1' = '695f93ebec4720783d2b7b7b782e7f38c9ec4675'
    'repo-d7ca3475' = '09a1a1cb42326fc207cdc09764c299f022d4c1e1'
    'repo-dcc1053e' = '48175a82713684373d85acdb77af4a45745e7cd1'
    'repo-de4c3e15' = 'a35ef822f41dc6e785730b2d1aeb3b75c78f0c2c'
    'repo-e2b0fb07' = '9965378dbb5cd9f371210e96574223ab30c0dc2c'
    'repo-e2c08e63' = 'fa4b05a8c6f6b7b9030ab1efb176fd27bf19adf5'
    'repo-f65f1d5c' = 'aef9d7a9c9178865b4ef7826b9e615f5e7d1b495'
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingTree,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $previousPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 wraps native stderr (including harmless Git
        # autocrlf warnings) in NativeCommandError when Stop is active.
        $ErrorActionPreference = 'Continue'
        $output = @(& git -C $WorkingTree @Arguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if (-not $AllowFailure -and $code -ne 0) {
        throw "git -C '$WorkingTree' $($Arguments -join ' ') failed ($code):`n$($output -join "`n")"
    }
    return [pscustomobject]@{ Code = $code; Output = $output }
}

function Get-SemanticDirtyState {
    param([Parameter(Mandatory = $true)][string]$Path)
    $unstaged = Invoke-Git -WorkingTree $Path -Arguments @('diff', '--quiet', '--ignore-submodules', '--') -AllowFailure
    $staged = Invoke-Git -WorkingTree $Path -Arguments @('diff', '--cached', '--quiet', '--ignore-submodules', '--') -AllowFailure
    $untracked = Invoke-Git -WorkingTree $Path -Arguments @('ls-files', '--others', '--exclude-standard')
    return [pscustomobject]@{
        TrackedDirty = ($unstaged.Code -ne 0 -or $staged.Code -ne 0)
        Untracked = @($untracked.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
}

function Stop-DisposableWorktreeProcesses {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $safeProcessNames = @(
        'flutter_tester.exe',
        'dart.exe',
        'dartaotruntime.exe',
        'java.exe',
        'javaw.exe',
        'msbuild.exe',
        'cmake.exe',
        'ninja.exe',
        'cl.exe',
        'link.exe',
        'im_client.exe'
    )
    $escapedPath = [regex]::Escape($Path)
    $matches = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $safeProcessNames -contains $_.Name -and
        (($_.CommandLine -match $escapedPath) -or ($_.ExecutablePath -match $escapedPath))
    })
    if ($matches.Count -eq 0) {
        return
    }

    foreach ($process in $matches) {
        if ($WhatIf) {
            Write-Host "[WHATIF] stop stale $($process.Name) PID $($process.ProcessId) for $Name"
            continue
        }
        Write-Host "[stop] stale $($process.Name) PID $($process.ProcessId) for $Name"
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
    }
    if (-not $WhatIf) {
        Start-Sleep -Milliseconds 500
        $stillRunning = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $safeProcessNames -contains $_.Name -and
            (($_.CommandLine -match $escapedPath) -or ($_.ExecutablePath -match $escapedPath))
        })
        if ($stillRunning.Count -gt 0) {
            throw "stale build/test processes still hold ${Name}: $($stillRunning.ProcessId -join ', ')"
        }
    }
}

function Remove-PhysicalDirectoryLongPathSafe {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $extendedPath = if ($Path.StartsWith('\\?\')) { $Path } else { '\\?\' + $Path }
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & cmd.exe /d /c "rd /s /q `"$extendedPath`"" 2>&1 | Out-Host
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($code -ne 0 -or (Test-Path -LiteralPath $Path)) {
        throw "extended-length path removal failed: $Name"
    }
}

function Remove-WorktreeLongPathSafe {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path
    )

    Stop-DisposableWorktreeProcesses -Name $Name -Path $Path

    $result = Invoke-Git -WorkingTree $Root -Arguments @(
        '-c', 'core.longpaths=true',
        'worktree', 'remove', '--force', $Path
    ) -AllowFailure
    if ($result.Code -eq 0) {
        return
    }

    $message = ($result.Output -join "`n")
    if ($message -notmatch '(?i)filename too long|path too long|too long|permission denied|access is denied|access denied') {
        throw "git worktree remove failed: $Name`n$message"
    }

    Write-Host "[fallback] Git could not fully remove $Name; using extended-length Windows path fallback"
    Remove-PhysicalDirectoryLongPathSafe -Name $Name -Path $Path

    $prune = Invoke-Git -WorkingTree $Root -Arguments @('-c', 'core.longpaths=true', 'worktree', 'prune') -AllowFailure
    if ($prune.Code -ne 0) {
        throw "worktree directory was removed, but git worktree prune failed for $Name`n$($prune.Output -join "`n")"
    }
}

function Save-DetachedHeadRef {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Head
    )
    $branch = (Invoke-Git -WorkingTree $Path -Arguments @('branch', '--show-current')).Output -join ''
    if ([string]::IsNullOrWhiteSpace($branch)) {
        $ref = "refs/archive/worktrees/$Name"
        if ($WhatIf) {
            Write-Host "[WHATIF] preserve detached HEAD $Head as $ref"
        }
        else {
            & git -C $Root update-ref $ref $Head
            if ($LASTEXITCODE -ne 0) { throw "failed to preserve $Name detached HEAD" }
        }
    }
}

function Archive-RepoDe4Draft {
    param([Parameter(Mandatory = $true)][string]$Path)
    $allowed = @(
        'clients/app/android/app/build.gradle.kts',
        '.github/workflows/release.yml',
        'CHANGELOG.md',
        'scripts/test-release-pipeline.ps1'
    )
    $state = Invoke-Git -WorkingTree $Path -Arguments @('status', '--porcelain')
    $actual = @($state.Output | ForEach-Object { $_.Substring(3) } | Sort-Object -Unique)
    $unexpected = @($actual | Where-Object { $allowed -notcontains $_ })
    if ($unexpected.Count -gt 0) {
        throw "repo-de4c3e15 has unexpected dirty files; refusing cleanup: $($unexpected -join ', ')"
    }

    if ($WhatIf) {
        Write-Host "[WHATIF] archive old release draft from repo-de4c3e15 to $ArchiveRoot"
        return
    }

    $dest = Join-Path $ArchiveRoot 'repo-de4c3e15-old-release-draft'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $patch = & git -C $Path diff --binary -- clients/app/android/app/build.gradle.kts 2>&1
    $patch | Out-File -LiteralPath (Join-Path $dest 'tracked.patch') -Encoding utf8
    foreach ($file in $allowed | Where-Object { $_ -ne 'clients/app/android/app/build.gradle.kts' }) {
        $source = Join-Path $Path $file
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            $target = Join-Path $dest $file
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $target -Force
        }
    }
    Write-Host "[archive] repo-de4c3e15 old draft -> $dest"
}

function Assert-RepoE2cAlreadyInMaster {
    param([Parameter(Mandatory = $true)][string]$Path)
    $state = Get-SemanticDirtyState -Path $Path
    if ($state.TrackedDirty) {
        throw 'repo-e2c08e63 has tracked changes; refusing cleanup.'
    }
    foreach ($file in $state.Untracked) {
        $workHash = (& git hash-object (Join-Path $Path $file)).Trim()
        $masterHash = @(& git -C $Root rev-parse "master:$file" 2>$null)
        if ($LASTEXITCODE -ne 0 -or $masterHash.Count -eq 0 -or $workHash -ne $masterHash[0].Trim()) {
            throw "repo-e2c08e63 untracked file is not identical to master: $file"
        }
    }
}

Push-Location $Root
try {
    $main = (Resolve-Path -LiteralPath $Root).Path
    $wave3 = (Resolve-Path -LiteralPath $KeepWave3).Path
    Write-Host "Keep main:  $main"
    Write-Host "Keep Wave3: $wave3"
    Write-Host ''

    foreach ($entry in $Disposable.GetEnumerator()) {
        $name = $entry.Key
        $expectedHead = $entry.Value
        $path = "C:\Users\admin\.devspace\worktrees\$name"
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            Write-Host "[skip] $name already absent"
            continue
        }

        $gitMarker = Join-Path $path '.git'
        if (-not (Test-Path -LiteralPath $gitMarker)) {
            $archiveRef = "refs/archive/worktrees/$name"
            $archivedHead = ((Invoke-Git -WorkingTree $Root -Arguments @('rev-parse', $archiveRef)).Output -join '').Trim()
            if ($archivedHead -ne $expectedHead) {
                throw "$name is an orphaned directory without .git and has no matching safety archive ref. Refusing cleanup."
            }
            if ($WhatIf) {
                Write-Host "[WHATIF] remove orphaned physical directory $name ($expectedHead)"
            }
            else {
                Write-Host "[orphan] removing already-unregistered directory $name"
                Stop-DisposableWorktreeProcesses -Name $name -Path $path
                Remove-PhysicalDirectoryLongPathSafe -Name $name -Path $path
                Write-Host "[removed] $name"
            }
            continue
        }

        $head = ((Invoke-Git -WorkingTree $path -Arguments @('rev-parse', 'HEAD')).Output -join '').Trim()
        if ($head -ne $expectedHead) {
            throw "$name HEAD changed. Expected $expectedHead, got $head. Refusing cleanup."
        }

        if ($name -eq 'repo-de4c3e15') {
            Archive-RepoDe4Draft -Path $path
        }
        elseif ($name -eq 'repo-e2c08e63') {
            Assert-RepoE2cAlreadyInMaster -Path $path
        }
        else {
            $dirty = Get-SemanticDirtyState -Path $path
            if ($dirty.TrackedDirty -or $dirty.Untracked.Count -gt 0) {
                throw "$name contains real uncommitted changes; refusing cleanup."
            }
        }

        Save-DetachedHeadRef -Name $name -Path $path -Head $head
        if ($WhatIf) {
            Write-Host "[WHATIF] remove $name ($head)"
        }
        else {
            Remove-WorktreeLongPathSafe -Name $name -Path $path
            Write-Host "[removed] $name"
        }
    }

    if (-not $WhatIf) {
        & git -C $Root worktree prune
        if ($LASTEXITCODE -ne 0) { throw 'git worktree prune failed.' }
    }

    Write-Host ''
    Write-Host 'Remaining worktrees:'
    & git -C $Root worktree list
    Write-Host ''
    Write-Host 'NOTE: master was NOT fast-forwarded to Wave2 because the main checkout has real uncommitted docs/tasks.'
    Write-Host 'Wave2 branch ref is preserved: integrate/2026-08-14-wave2 @ 6ac4e6e6c2d37a234cde3219bb4ce5685a0c5298'
    Write-Host 'Current Wave3 dirty worktree is preserved intact: repo-503b2173'
    if (-not $WhatIf -and (Test-Path -LiteralPath $ArchiveRoot)) {
        Write-Host "Safety archive: $ArchiveRoot"
    }
}
finally {
    Pop-Location
}
