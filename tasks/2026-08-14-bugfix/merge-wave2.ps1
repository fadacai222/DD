param(
    [switch]$SkipBuilds,
    [switch]$SkipRealPg
)

$ErrorActionPreference = 'Stop'
$env:GIT_EDITOR = 'true'

# Keep this script ASCII-only for Windows PowerShell 5.1 compatibility.
$Base = 'b601d98317fb3478d3c84227a4ee9dac76d0ae17'
$Integration = 'C:\Users\admin\.devspace\worktrees\repo-322bafc2'
$IntegrationBranch = 'integrate/2026-08-14-wave2'
$Ai08 = 'C:\Users\admin\.devspace\worktrees\repo-0ccd5cae'
$Ai08FollowupSubject = 'fix(voice): requeue retryable transcription failures'
$ShellLfPolicySubject = 'chore(repo): enforce LF for shell scripts'
$GeneratedRegistrant = 'clients/app/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java'

function Invoke-Git {
    param([Parameter(Mandatory=$true)][string[]]$GitArgs)
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') failed"
    }
}

function Get-CommitByExactSubject {
    param([Parameter(Mandatory=$true)][string]$Subject)
    $row = (& git log --format='%H%x09%s' -n 40 | Where-Object {
        $parts = $_ -split "`t", 2
        $parts.Count -eq 2 -and $parts[1] -eq $Subject
    } | Select-Object -First 1)
    if (-not $row) { return $null }
    return (($row -split "`t", 2)[0]).Trim()
}

function Test-SubjectAlreadyIntegrated {
    param([Parameter(Mandatory=$true)][string]$Commit)
    $subject = (& git show -s --format='%s' $Commit).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Cannot read commit subject for $Commit" }
    $subjects = @(& git log --format='%s' "$Base..HEAD")
    return ($subjects -contains $subject)
}

function Restore-GeneratedRegistrant {
    & git restore --staged --worktree -- $GeneratedRegistrant 2>$null
    if ($LASTEXITCODE -ne 0) {
        $global:LASTEXITCODE = 0
    }
}

function Get-SemanticDirtyPaths {
    $paths = @()

    $paths += @(& git diff --name-only --no-ext-diff)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect unstaged Git diff.' }

    $paths += @(& git diff --cached --name-only --no-ext-diff)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect staged Git diff.' }

    $paths += @(& git ls-files --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect untracked Git files.' }

    return @($paths | Where-Object { $_ -and $_.Trim() -ne '' } | Sort-Object -Unique)
}

function Ensure-ShellLfPolicy {
    param([Parameter(Mandatory=$true)][string]$Root)

    Set-Location $Root
    $attributesPath = Join-Path $Root '.gitattributes'
    $policyLine = '*.sh text eol=lf'
    if (-not (Test-Path -LiteralPath $attributesPath)) {
        [IO.File]::WriteAllText(
            $attributesPath,
            "# Shell scripts must remain LF even when checked out from Windows.`n$policyLine`n",
            [Text.UTF8Encoding]::new($false)
        )
    } else {
        $attributes = [IO.File]::ReadAllText($attributesPath)
        $lines = @($attributes -split "`r?`n")
        if (-not ($lines -contains $policyLine)) {
            $separator = if ($attributes.EndsWith("`n")) { '' } else { "`n" }
            [IO.File]::WriteAllText(
                $attributesPath,
                $attributes + $separator + $policyLine + "`n",
                [Text.UTF8Encoding]::new($false)
            )
        }
    }

    $attributeStatus = @(& git status --porcelain -- '.gitattributes')
    if ($attributeStatus.Count -gt 0) {
        Invoke-Git -GitArgs @('add', '--', '.gitattributes')
        Invoke-Git -GitArgs @('commit', '-m', $ShellLfPolicySubject)
    }

    $shellFiles = @(& git ls-files ':(glob)**/*.sh')
    if ($shellFiles.Count -gt 0) {
        # git restore may skip a rewrite when CRLF and LF normalize to the same
        # index content. checkout-index --force always rematerializes from index
        # and therefore applies the eol=lf working-tree rule.
        $checkoutArgs = @('checkout-index', '--force', '--') + $shellFiles
        Invoke-Git -GitArgs $checkoutArgs
    }

    $badShellEol = @(& git ls-files --eol ':(glob)**/*.sh' | Where-Object {
        $_ -match 'w/(crlf|mixed)'
    })
    if ($badShellEol.Count -gt 0) {
        # Defensive fallback for Windows Git installations where an existing
        # worktree file can still survive checkout filters. Normalize bytes
        # directly without changing the canonical index content.
        foreach ($shellFile in $shellFiles) {
            $fullPath = Join-Path $Root ($shellFile -replace '/', '\\')
            $bytes = [IO.File]::ReadAllBytes($fullPath)
            $output = New-Object 'System.Collections.Generic.List[byte]'
            for ($index = 0; $index -lt $bytes.Length; $index++) {
                if ($bytes[$index] -eq 13) {
                    if (($index + 1) -lt $bytes.Length -and $bytes[$index + 1] -eq 10) {
                        continue
                    }
                    $output.Add([byte]10)
                    continue
                }
                $output.Add($bytes[$index])
            }
            [IO.File]::WriteAllBytes($fullPath, $output.ToArray())
        }

        $badShellEol = @(& git ls-files --eol ':(glob)**/*.sh' | Where-Object {
            $_ -match 'w/(crlf|mixed)'
        })
    }

    if ($badShellEol.Count -gt 0) {
        $badShellEol | ForEach-Object { Write-Host $_ }
        throw 'Tracked shell scripts are still checked out with CRLF/mixed EOL after forced normalization.'
    }
}

function Replace-RequiredText {
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][string]$Old,
        [Parameter(Mandatory=$true)][string]$New,
        [Parameter(Mandatory=$true)][string]$Label
    )
    if (-not $Text.Contains($Old)) {
        throw "Known Wave2 conflict resolver could not find: $Label"
    }
    return $Text.Replace($Old, $New)
}

function Resolve-KnownDataRightsConflict {
    param([Parameter(Mandatory=$true)][string]$Root)
    $path = Join-Path $Root 'server\internal\datarights\service_integration_test.go'
    $text = [IO.File]::ReadAllText($path)
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }

    $text = Replace-RequiredText -Text $text `
        -Old 'seedDataRightsBusinessData(t, ctx, pool, user1, device1, user2, now, suffix)' `
        -New 'seedDataRightsBusinessData(t, ctx, pool, user1, device1, user2, device2, now, suffix)' `
        -Label 'seed call device2'

    $mentionCleanup = @'
	var mentionRows int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM message_mentions WHERE mentioned_user_id=$1`, user1).Scan(&mentionRows); err != nil {
		t.Fatal(err)
	}
	if mentionRows != 0 {
		t.Fatalf("account deletion left %d durable mention rows", mentionRows)
	}
'@
    $mentionCleanup = ($mentionCleanup -replace "`r?`n", $nl).TrimEnd([char[]]"`r`n")
    $oldAuth = 'if _, err := authService.AuthenticateAccessToken(ctx, access.Raw); !errors.Is(err, account.ErrUnauthorized) {'
    $newAuth = 'if _, err := authService.AuthenticateAccessToken(ctx, access.Raw); !errors.Is(err, account.ErrUnauthorized) && !errors.Is(err, account.ErrDeviceSessionRevoked) {'
    $text = Replace-RequiredText -Text $text -Old ("`t" + $oldAuth) -New ($mentionCleanup + $nl + "`t" + $newAuth) -Label 'deleted-token and mention cleanup assertion'

    $text = Replace-RequiredText -Text $text `
        -Old "SELECT count(*) FROM media_objects WHERE id=`$1 AND owner_user_id IS NULL AND original_name='shared-media'" `
        -New 'SELECT count(*) FROM media_objects WHERE id=$1 AND owner_user_id IS NULL' `
        -Label 'Live Photo retained motion query'

    $text = Replace-RequiredText -Text $text `
        -Old 'user1, device1, user2 uuid.UUID, now time.Time, suffix string) (uuid.UUID, uuid.UUID, uuid.UUID, string, uuid.UUID)' `
        -New 'user1, device1, user2, device2 uuid.UUID, now time.Time, suffix string) (uuid.UUID, uuid.UUID, uuid.UUID, string, uuid.UUID)' `
        -Label 'seed helper device2 signature'

    $text = Replace-RequiredText -Text $text `
        -Old "INSERT INTO conversations(id,type,created_at,updated_at) VALUES(`$1,'GROUP',`$2,`$2)" `
        -New "INSERT INTO conversations(id,type,created_at,updated_at,last_sequence) VALUES(`$1,'GROUP',`$2,`$2,1)" `
        -Label 'group last sequence seed'

    $mentionSeed = @'
	groupMessageID := uuid.New()
	groupContent := fmt.Sprintf(`{"text":"@u1 retained mention","entities":[{"type":"MENTION","offset":0,"length":3,"userId":"%s","handle":"u1"}]}`, user1)
	if _, err := pool.Exec(ctx, `INSERT INTO messages(id,conversation_id,sequence,sender_user_id,sender_device_id,client_message_id,type,content_json,created_at) VALUES($1,$2,1,$3,$4,$5,'TEXT',$6::jsonb,$7)`, groupMessageID, groupID, user2, device2, "u12-mention-"+suffix, groupContent, now); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO message_mentions(message_id,conversation_id,sequence,mentioned_user_id,mention_all) VALUES($1,$2,1,$3,false)`, groupMessageID, groupID, user1); err != nil {
		t.Fatal(err)
	}
'@
    $mentionSeed = ($mentionSeed -replace "`r?`n", $nl).TrimEnd([char[]]"`r`n")
    $privateMarker = "`tprivateMediaID := uuid.New()"
    $text = Replace-RequiredText -Text $text -Old $privateMarker -New ($mentionSeed + $nl + $nl + $privateMarker) -Label 'durable mention seed'

    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
}

Write-Host '[1/5] Commit coordinator AI08 retry follow-up'
Set-Location $Ai08
Restore-GeneratedRegistrant
$Ai08Followup = Get-CommitByExactSubject -Subject $Ai08FollowupSubject
$followupFiles = @(
    'server/internal/transcription/service.go',
    'server/internal/transcription/service_integration_test.go'
)
$followupStatus = @(& git status --porcelain -- $followupFiles)
$allStatus = @(& git status --porcelain)

if ($followupStatus.Count -gt 0) {
    if ($Ai08Followup) {
        throw 'AI08 retry follow-up already exists but the same files are still modified.'
    }
    if ($allStatus.Count -ne $followupStatus.Count) {
        & git status --short
        throw 'AI08 worktree contains unexpected changes outside the coordinator follow-up.'
    }
    $addArgs = @('add', '--') + $followupFiles
    Invoke-Git -GitArgs $addArgs
    Invoke-Git -GitArgs @('commit', '-m', $Ai08FollowupSubject)
    $Ai08Followup = (& git rev-parse HEAD).Trim()
} elseif (-not $Ai08Followup) {
    throw 'AI08 retry follow-up is neither pending nor already committed.'
}

Restore-GeneratedRegistrant
$ai08Dirty = @(Get-SemanticDirtyPaths)
if ($ai08Dirty.Count -ne 0) {
    $ai08Dirty | ForEach-Object { Write-Host $_ }
    throw 'AI08 worktree is not clean after the coordinator follow-up commit.'
}

Write-Host '[2/5] Build Wave2 integration branch'
Set-Location $Integration
Restore-GeneratedRegistrant
$unexpectedBeforeBranch = @(Get-SemanticDirtyPaths | Where-Object {
    $_ -ne '.gitattributes'
})
if ($unexpectedBeforeBranch.Count -ne 0) {
    $unexpectedBeforeBranch | ForEach-Object { Write-Host $_ }
    throw 'Wave2 integration worktree has unexpected changes before branch setup.'
}

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

Ensure-ShellLfPolicy -Root $Integration
$dirtyAfterShellLf = @(Get-SemanticDirtyPaths)
if ($dirtyAfterShellLf.Count -ne 0) {
    $dirtyAfterShellLf | ForEach-Object { Write-Host $_ }
    throw 'Wave2 integration worktree has real content changes after shell LF normalization.'
}

$commits = @(
    '09a1a1cb42326fc207cdc09764c299f022d4c1e1',
    '360ac7f89f4bc565a8badf6055727dfd13c003cb',
    'a17b6911e84209a8107e2d558f425dacb3564528',
    '76ca96ed0fa930104d0c600c747d21cc64aa3972',
    '2acdc81c896de310f791452b70c06aadab84f3a8',
    $Ai08Followup,
    '9965378dbb5cd9f371210e96574223ab30c0dc2c',
    'b0d3cb434e7aadd75148feba391a25342203f027'
)

foreach ($commit in $commits) {
    if (Test-SubjectAlreadyIntegrated -Commit $commit) {
        Write-Host "skip already integrated: $commit"
        continue
    }

    & git cherry-pick $commit
    if ($LASTEXITCODE -eq 0) { continue }

    $conflicts = @(& git diff --name-only --diff-filter=U)
    $knownDataRights = 'server/internal/datarights/service_integration_test.go'
    $unexpected = @($conflicts | Where-Object {
        $_ -ne 'docs/README.md' -and $_ -notlike 'docs/15-*' -and $_ -ne $knownDataRights
    })
    $knownDataRightsAllowed = ($commit -eq 'b0d3cb434e7aadd75148feba391a25342203f027')
    if ($conflicts.Count -eq 0 -or $unexpected.Count -gt 0 -or (($conflicts -contains $knownDataRights) -and -not $knownDataRightsAllowed)) {
        & git cherry-pick --abort
        throw "Unexpected business-code conflict while cherry-picking $commit : $($conflicts -join ', ')"
    }

    if ($conflicts -contains $knownDataRights) {
        Invoke-Git -GitArgs @('checkout', '--theirs', '--', $knownDataRights)
        Resolve-KnownDataRightsConflict -Root $Integration
        Invoke-Git -GitArgs @('add', '--', $knownDataRights)
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

$requiredMigrations = @(
    'server/migrations/000034_message_mentions.up.sql',
    'server/migrations/000035_voice_transcriptions.up.sql',
    'server/migrations/000036_live_photo_message_media.up.sql'
)
foreach ($migration in $requiredMigrations) {
    if (-not (Test-Path -LiteralPath (Join-Path $Integration $migration))) {
        throw "Required Wave2 migration is missing: $migration"
    }
}

Write-Host '[3/5] Run combined real PostgreSQL smoke when available'
if (-not $SkipRealPg) {
    $pgContainer = 'dd-dev-postgres-1'
    $runningContainers = @(& docker ps --format '{{.Names}}' 2>$null)
    if ($LASTEXITCODE -eq 0 -and $runningContainers -contains $pgContainer) {
        $containerEnv = @(& docker inspect $pgContainer --format '{{range .Config.Env}}{{println .}}{{end}}')
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect dd-dev-postgres-1.' }
        $pgUserLine = $containerEnv | Where-Object { $_ -like 'POSTGRES_USER=*' } | Select-Object -First 1
        $pgPasswordLine = $containerEnv | Where-Object { $_ -like 'POSTGRES_PASSWORD=*' } | Select-Object -First 1
        $pgUser = if ($pgUserLine) { $pgUserLine.Substring('POSTGRES_USER='.Length) } else { 'dd' }
        if (-not $pgPasswordLine) { throw 'POSTGRES_PASSWORD is missing from dd-dev-postgres-1.' }
        $pgPassword = $pgPasswordLine.Substring('POSTGRES_PASSWORD='.Length)
        $encodedUser = [uri]::EscapeDataString($pgUser)
        $encodedPassword = [uri]::EscapeDataString($pgPassword)
        $testDb = 'dd_wave2_' + [guid]::NewGuid().ToString('N').Substring(0, 12)
        & docker exec $pgContainer createdb -U $pgUser $testDb
        if ($LASTEXITCODE -ne 0) { throw 'Create isolated Wave2 PostgreSQL database failed.' }

        $oldDatabaseUrl = $env:DATABASE_URL
        $oldMessagingUrl = $env:DD_MESSAGING_TEST_DATABASE_URL
        $oldMediaUrl = $env:DD_MEDIA_TEST_DATABASE_URL
        $oldDataRightsUrl = $env:DD_DATA_RIGHTS_TEST_DATABASE_URL
        $databaseUrl = "postgres://${encodedUser}:${encodedPassword}@127.0.0.1:15432/${testDb}?sslmode=disable"
        try {
            $env:DATABASE_URL = $databaseUrl
            $env:DD_MESSAGING_TEST_DATABASE_URL = $databaseUrl
            $env:DD_MEDIA_TEST_DATABASE_URL = $databaseUrl
            Set-Location (Join-Path $Integration 'server')

            & go run ./cmd/migrate up
            if ($LASTEXITCODE -ne 0) { throw 'Combined Wave2 migration up failed.' }
            & go test ./internal/messaging -run TestDurableUnreadMentionsWithPostgres -count=1
            if ($LASTEXITCODE -ne 0) { throw 'Combined durable mention PostgreSQL smoke failed.' }
            & go test ./internal/transcription -run TestVoiceTranscriptionLifecycleWithPostgres -count=1
            if ($LASTEXITCODE -ne 0) { throw 'Combined voice transcription PostgreSQL smoke failed.' }
            & go test ./internal/media -run TestLivePhotoMediaAuthorizationAndLifecycleWithPostgres -count=1
            if ($LASTEXITCODE -ne 0) { throw 'Combined Live Photo PostgreSQL smoke failed.' }
            $env:DD_DATA_RIGHTS_TEST_DATABASE_URL = $databaseUrl
            & go test ./internal/datarights -run TestDataRightsLifecycleWithPostgres -count=1
            if ($LASTEXITCODE -ne 0) { throw 'Combined Data Rights PostgreSQL smoke failed.' }
        }
        finally {
            $env:DATABASE_URL = $oldDatabaseUrl
            $env:DD_MESSAGING_TEST_DATABASE_URL = $oldMessagingUrl
            $env:DD_MEDIA_TEST_DATABASE_URL = $oldMediaUrl
            $env:DD_DATA_RIGHTS_TEST_DATABASE_URL = $oldDataRightsUrl
            & docker exec $pgContainer dropdb -U $pgUser --if-exists $testDb 2>$null
            Set-Location $Integration
        }
    } else {
        Write-Host '[SKIP] dd-dev-postgres-1 is not running; combined real-PG smoke skipped.'
        $global:LASTEXITCODE = 0
    }
} else {
    Write-Host '[SKIP] Combined real-PG smoke disabled by -SkipRealPg.'
}

Write-Host '[4/5] Run full repository gates'
Set-Location (Join-Path $Integration 'server')
& go test ./...
if ($LASTEXITCODE -ne 0) { throw 'go test ./... failed' }
& go vet ./...
if ($LASTEXITCODE -ne 0) { throw 'go vet ./... failed' }

Set-Location $Integration
& docker compose -f '.\infra\prod\compose.yml' config --no-interpolate
if ($LASTEXITCODE -ne 0) { throw 'Production compose config validation failed' }
$shellFiles = @(& git ls-files ':(glob)**/*.sh')
foreach ($shellFile in $shellFiles) {
    & bash -n $shellFile
    if ($LASTEXITCODE -ne 0) { throw "Shell syntax validation failed: $shellFile" }
}

Set-Location (Join-Path $Integration 'clients\realtime_poc')
& flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'realtime_poc flutter pub get failed' }
& flutter test
if ($LASTEXITCODE -ne 0) { throw 'realtime_poc flutter test failed' }

Set-Location (Join-Path $Integration 'clients\app')
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
}

Write-Host '[5/5] Wave2 checkpoint ready'
Set-Location $Integration
Restore-GeneratedRegistrant
Invoke-Git -GitArgs @('diff', '--check', $Base, 'HEAD')
$finalDirty = @(Get-SemanticDirtyPaths)
if ($finalDirty.Count -ne 0) {
    $finalDirty | ForEach-Object { Write-Host $_ }
    throw 'Wave2 integration worktree has real content changes after gates.'
}
$Checkpoint = (& git rev-parse HEAD).Trim()
Write-Host "WAVE3_BASE_COMMIT=$Checkpoint"
Write-Host "AI08_RETRY_FOLLOWUP=$Ai08Followup"
Write-Host 'Wave2 is integrated only on integrate/2026-08-14-wave2; dirty master was not modified.'
