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

function Invoke-GitChecked {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $Output = @(& git -C $Root @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $ExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }

    if ($ExitCode -ne 0) {
        throw "Git metadata check failed (git $($Arguments -join ' ')): $($Output -join [Environment]::NewLine)"
    }
    return $Output
}

function Resolve-GitMetadataPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Get-GitMetadataDirectories {
    $DotGit = Join-Path $Root '.git'
    if (Test-Path -LiteralPath $DotGit -PathType Container) {
        $GitDir = [System.IO.Path]::GetFullPath($DotGit)
    }
    elseif (Test-Path -LiteralPath $DotGit -PathType Leaf) {
        # A linked worktree stores a gitfile rather than a .git directory.
        # Parse it directly so Windows PowerShell 5.1 never has to decode a
        # non-ASCII absolute path emitted by a native git.exe process.
        $GitFile = (Get-Content -LiteralPath $DotGit -Raw -Encoding UTF8).Trim()
        $Match = [regex]::Match($GitFile, '^gitdir:\s*(.+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $Match.Success) {
            throw "Invalid Git worktree metadata file: $DotGit"
        }
        $GitDir = Resolve-GitMetadataPath -Path $Match.Groups[1].Value.Trim() -BasePath $Root
    }
    else {
        throw "Git repository metadata is missing: $DotGit"
    }

    if (-not (Test-Path -LiteralPath $GitDir -PathType Container)) {
        throw "Git worktree metadata directory is not accessible: $GitDir"
    }

    $CommonDirFile = Join-Path $GitDir 'commondir'
    if (Test-Path -LiteralPath $CommonDirFile -PathType Leaf) {
        $CommonDirRaw = (Get-Content -LiteralPath $CommonDirFile -Raw -Encoding UTF8).Trim()
        if (-not $CommonDirRaw) {
            throw "Git commondir metadata is empty: $CommonDirFile"
        }
        $CommonDir = Resolve-GitMetadataPath -Path $CommonDirRaw -BasePath $GitDir
    }
    else {
        $CommonDir = $GitDir
    }

    if (-not (Test-Path -LiteralPath $CommonDir -PathType Container)) {
        throw "Git common metadata directory is not accessible: $CommonDir"
    }

    return [PSCustomObject]@{
        GitDir = $GitDir
        CommonDir = $CommonDir
    }
}

function Get-HistoryScanContext {
    $null = Get-Command git -ErrorAction Stop

    $InsideWorkTree = (Invoke-GitChecked -Arguments @('rev-parse', '--is-inside-work-tree') | Select-Object -Last 1).Trim()
    if ($InsideWorkTree -ne 'true') {
        throw "Secret scan root is not a Git worktree: $Root"
    }

    $IsShallow = (Invoke-GitChecked -Arguments @('rev-parse', '--is-shallow-repository') | Select-Object -Last 1).Trim()
    if ($IsShallow -ne 'false') {
        throw 'Full-history secret scan requires a non-shallow repository. GitHub Actions must keep actions/checkout fetch-depth: 0.'
    }

    $Metadata = Get-GitMetadataDirectories
    $GitDir = $Metadata.GitDir
    $CommonDir = $Metadata.CommonDir

    $Head = (Invoke-GitChecked -Arguments @('rev-parse', '--verify', 'HEAD') | Select-Object -Last 1).Trim()
    # Match the explicit Gitleaks log scope below: every reachable ref plus the
    # current HEAD. Including HEAD matters for detached linked worktrees and CI
    # checkouts whose commit may not yet be named by a local branch ref.
    $CountRaw = (Invoke-GitChecked -Arguments @('rev-list', '--count', '--all', 'HEAD') | Select-Object -Last 1).Trim()
    $CommitCount = 0
    if (-not [int]::TryParse($CountRaw, [ref]$CommitCount) -or $CommitCount -le 0) {
        throw "Full-history secret scan cannot prove a non-zero Git history at HEAD ${Head}: '$CountRaw'."
    }

    $TrimmedCommonDir = $CommonDir.TrimEnd([char[]]'\/')
    $TrimmedGitDir = $GitDir.TrimEnd([char[]]'\/')
    $Comparison = [System.StringComparison]::Ordinal
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $Comparison = [System.StringComparison]::OrdinalIgnoreCase
    }

    if ([string]::Equals($TrimmedGitDir, $TrimmedCommonDir, $Comparison)) {
        $ContainerGitDir = '/git-common'
    }
    else {
        $Prefix = $TrimmedCommonDir + [System.IO.Path]::DirectorySeparatorChar
        if (-not $TrimmedGitDir.StartsWith($Prefix, $Comparison)) {
            throw "Git worktree metadata must live under the common Git directory. gitdir='$GitDir' common='$CommonDir'."
        }
        $RelativeGitDir = $TrimmedGitDir.Substring($Prefix.Length).Replace('\', '/')
        $ContainerGitDir = "/git-common/$RelativeGitDir"
    }

    return [PSCustomObject]@{
        Head = $Head
        CommitCount = $CommitCount
        GitDir = $GitDir
        CommonDir = $CommonDir
        ContainerGitDir = $ContainerGitDir
    }
}

function Assert-HistoryScanEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Output,
        [Parameter(Mandatory = $true)]
        [int]$ExpectedCommitCount
    )

    $Text = $Output -join "`n"
    if ($Text -match '(?im)\bfatal:') {
        throw 'Gitleaks emitted a Git fatal error during the full-history scan.'
    }

    $CommitMatches = [regex]::Matches($Text, '(?im)\b(\d+)\s+commits scanned\.')
    if ($CommitMatches.Count -eq 0) {
        throw 'Gitleaks full-history scan did not report how many Git commits were scanned.'
    }

    $ScannedCommitCount = [int]$CommitMatches[$CommitMatches.Count - 1].Groups[1].Value
    if ($ScannedCommitCount -le 0) {
        throw 'Gitleaks reported 0 commits scanned; refusing a false-green Secret Scan.'
    }
    if ($ScannedCommitCount -ne $ExpectedCommitCount) {
        throw "Gitleaks scanned $ScannedCommitCount commits, but Git reports $ExpectedCommitCount commits reachable from all refs plus HEAD. Full-history evidence is incomplete."
    }

    Write-Host "[secret-scan] verified history evidence: Gitleaks scanned $ScannedCommitCount/$ExpectedCommitCount commits reachable from all refs plus HEAD."
}

function Invoke-GitleaksHistoryScan {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Context,
        [string]$ContainerGitDirOverride = ''
    )

    $ContainerGitDir = $Context.ContainerGitDir
    if ($ContainerGitDirOverride) {
        $ContainerGitDir = $ContainerGitDirOverride
    }

    $RootMount = "${Root}:/repo:ro"
    $CommonGitMount = "$($Context.CommonDir):/git-common:ro"
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $Output = @(& docker run --rm `
            --network none `
            --volume $RootMount `
            --volume $CommonGitMount `
            --workdir /repo `
            --env "GIT_DIR=$ContainerGitDir" `
            --env 'GIT_WORK_TREE=/repo' `
            $Image `
            git `
            --log-opts '--all HEAD --diff-merges=first-parent' `
            --config /repo/.gitleaks.toml `
            --redact `
            --no-banner `
            --no-color `
            --max-archive-depth 2 `
            --max-decode-depth 2 `
            /repo 2>&1 | ForEach-Object { $_.ToString() })
        $ExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }

    foreach ($Line in $Output) {
        Write-Host $Line
    }
    if ($ExitCode -ne 0) {
        throw "Gitleaks repository scan failed with exit code $ExitCode."
    }

    Assert-HistoryScanEvidence -Output $Output -ExpectedCommitCount $Context.CommitCount
}

function Assert-FalseGreenHistoryIsRejected {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Context
    )

    Write-Host '[secret-scan] verifying broken Git metadata cannot produce a false-green history scan...'
    $Rejected = $false
    try {
        Invoke-GitleaksHistoryScan -Context $Context -ContainerGitDirOverride '/git-common/worktrees/dd-intentionally-missing'
    }
    catch {
        $Rejected = $true
        Write-Host "[secret-scan] false-green guard rejected broken metadata: $($_.Exception.Message)"
    }
    if (-not $Rejected) {
        throw 'Gitleaks false-green self-test failed: broken Git metadata was accepted.'
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
            --network none `
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
$HistoryContext = Get-HistoryScanContext
Write-Host "[secret-scan] scanning full Git history at $($HistoryContext.Head) ($($HistoryContext.CommitCount) commits reachable from all refs plus HEAD)..."
Invoke-GitleaksHistoryScan -Context $HistoryContext
Assert-FalseGreenHistoryIsRejected -Context $HistoryContext
Assert-DetectorRejectsKnownLeak
Write-Host '[secret-scan] PASS'
