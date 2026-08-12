$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$WorkflowPath = Join-Path $Root '.github/workflows/release.yml'
$ContractPath = Join-Path $Root 'scripts/release/release_contract.py'
$RetentionPath = Join-Path $Root 'release/retention-policy.json'
$CodemagicPath = Join-Path $Root 'codemagic.yaml'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Match {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [string]$Pattern,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    if ($Text -notmatch $Pattern) {
        throw $Message
    }
}

function Invoke-ExpectedFailure {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Action
        $ExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $Previous
    }
    if ($ExitCode -eq 0) {
        throw $Message
    }
}

$Workflow = Get-Content -LiteralPath $WorkflowPath -Raw -Encoding UTF8
$Contract = Get-Content -LiteralPath $ContractPath -Raw -Encoding UTF8
$Retention = Get-Content -LiteralPath $RetentionPath -Raw -Encoding UTF8 | ConvertFrom-Json
$Codemagic = Get-Content -LiteralPath $CodemagicPath -Raw -Encoding UTF8

$ReleaseTestRoot = Join-Path $Root 'scripts/release'
Push-Location $ReleaseTestRoot
try {
    & python -m unittest -v test_release_contract.py
    if ($LASTEXITCODE -ne 0) {
        throw "Release contract unit tests failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

Assert-Match $Workflow '(?ms)^on:\s*\r?\n\s+push:\s*\r?\n\s+tags:\s*\r?\n\s+- ''v\*''' 'Formal release must be tag-triggered by v*.'
Assert-True ($Workflow -notmatch '(?m)^\s*workflow_dispatch\s*:') 'Formal release must not expose a non-tag workflow_dispatch publication path.'
Assert-Match $Workflow '(?m)^permissions:\s*\{\}\s*$' 'Release workflow must default-deny GitHub token permissions.'
Assert-Match $Workflow '(?m)^\s+environment:\s+release-signing\s*$' 'Native signing jobs must use the release-signing Environment.'
Assert-Match $Workflow '(?m)^\s+environment:\s+production-release\s*$' 'Final publication must be bound to the production-release Environment.'
Assert-Match $Workflow '--workflow ci\.yml' 'Release must verify the exact-SHA main CI workflow.'
Assert-Match $Workflow '--workflow secret-scan\.yml' 'Release must verify the exact-SHA Secret Scan workflow.'
Assert-Match $Workflow 'DD_ANDROID_REQUIRE_PROD_SIGNING:\s*''true''' 'Formal Android release must forbid debug-signing fallback.'
Assert-Match $Workflow 'DD_ANDROID_CERT_SHA256' 'Android signer certificate digest contract is missing.'
Assert-Match $Workflow 'DD_WINDOWS_CERT_THUMBPRINT' 'Windows Authenticode certificate identity contract is missing.'
Assert-Match $Workflow '(?m)^  build-ios:' 'Formal release DAG must contain build-ios.'
Assert-Match $Workflow 'DD_CODEMAGIC_API_TOKEN' 'Codemagic API token contract is missing.'
Assert-Match $Workflow 'DD_CODEMAGIC_APP_ID' 'Codemagic application identity contract is missing.'
Assert-Match $Codemagic '(?m)^  ios-unsigned-validation:' 'Unsigned iOS compile-validation workflow is missing.'
Assert-Match $Codemagic 'flutter build ios --debug --no-codesign' 'Unsigned iOS validation must perform a real no-codesign compile.'
Assert-Match $Codemagic '(?m)^  ios-signed-release:' 'Signed iOS release workflow is missing.'
Assert-Match $Codemagic 'app_store_connect:\s*DD_APP_STORE_CONNECT' 'Codemagic Apple integration contract is missing.'
Assert-Match $Codemagic '- dd_ios_release' 'Codemagic protected iOS release variable group is missing.'
Assert-Match $Codemagic 'DD_IOS_BUNDLE_ID' 'Signed iOS workflow must require Bundle identity.'
Assert-Match $Codemagic 'DD_IOS_TEAM_ID' 'Signed iOS workflow must require Team identity.'
Assert-Match $Codemagic 'fetch-signing-files' 'Signed iOS workflow must fetch App Store signing files.'
Assert-Match $Codemagic 'security find-identity' 'Signed iOS workflow must fail when distribution certificate identity is unavailable.'
Assert-Match $Codemagic 'codesign --verify --deep --strict' 'Signed iOS workflow must verify the native Apple signature.'
Assert-Match $Codemagic 'security cms -D -i' 'Signed iOS workflow must inspect the embedded provisioning profile.'
Assert-Match $Codemagic 'flutter build ipa --release' 'Signed iOS workflow must create a Release IPA.'
Assert-Match $Codemagic 'submit_to_app_store:\s*false' 'iOS workflow must not automatically submit to Production App Store.'
Assert-Match $Codemagic 'DD_IOS_MARKETING_VERSION' 'iOS prerelease-safe marketing-version mapping is missing.'
Assert-Match $Contract 'a release commit may have exactly one DD formal SemVer tag' 'Formal release tag uniqueness guard is missing.'
Assert-Match $Codemagic "SYFT_VERSION='[0-9]+\.[0-9]+\.[0-9]+'" 'Codemagic iOS Syft scanner version must be pinned.'
Assert-Match $Codemagic "TRIVY_VERSION='[0-9]+\.[0-9]+\.[0-9]+'" 'Codemagic iOS Trivy scanner version must be pinned.'
Assert-Match $Codemagic "SYFT_CHECKSUMS_SHA256='[0-9a-f]{64}'" 'Codemagic iOS Syft checksum integrity pin is missing.'
Assert-Match $Codemagic "TRIVY_CHECKSUMS_SHA256='[0-9a-f]{64}'" 'Codemagic iOS Trivy checksum integrity pin is missing.'
Assert-Match $Codemagic 'shasum -a 256 -c' 'Codemagic iOS scanner downloads must be checksum-verified.'
Assert-Match $Codemagic '--severity HIGH,CRITICAL' 'Codemagic resolved iOS native dependency scan must gate HIGH/CRITICAL findings.'
Assert-Match $Codemagic '--exit-code 1' 'Codemagic resolved iOS native dependency scan must fail closed.'
Assert-Match $Codemagic 'ios-codemagic-resolved\.spdx\.json' 'Codemagic resolved iOS SPDX SBOM artifact is missing.'
Assert-Match $Codemagic 'ios-codemagic-resolved\.trivy\.json' 'Codemagic resolved iOS Trivy report artifact is missing.'
$IosScanIndex = $Codemagic.IndexOf('- name: Scan resolved iOS dependencies before App Store Connect upload')
$PublishingIndex = $Codemagic.IndexOf('    publishing:')
Assert-True ($IosScanIndex -ge 0 -and $PublishingIndex -gt $IosScanIndex) 'Resolved iOS Trivy/Syft gate must run before App Store Connect publishing.'
Assert-Match $Workflow 'codemagic_ios_bridge\.py' 'Formal release must trigger the Codemagic signed iOS workflow.'
Assert-Match $Workflow 'verify-ios-ipa' 'Downloaded iOS IPA must pass release-contract validation.'
Assert-Match $Workflow 'ios-arm64\.ipa' 'Versioned iOS IPA naming contract is missing.'
Assert-Match $Workflow 'ios-codemagic-resolved\.spdx\.json' 'Codemagic pre-publish iOS SPDX SBOM must enter the GitHub release bundle.'
Assert-Match $Workflow 'ios-codemagic-resolved\.trivy\.json' 'Codemagic pre-publish iOS Trivy report must enter the GitHub release bundle.'
Assert-Match $Workflow 'ios-github-verified\.spdx\.json' 'GitHub-verified iOS SPDX SBOM is missing.'
Assert-Match $Workflow 'ios-github-verified\.trivy\.json' 'GitHub-verified iOS Trivy report is missing.'
Assert-Match $Workflow '\$signtool\.FullName verify' 'Windows Authenticode verification is missing.'
Assert-Match $Workflow 'apksigner.*verify' 'Android APK signature verification is missing.'
Assert-Match $Workflow '--severity HIGH,CRITICAL' 'HIGH/CRITICAL vulnerability gate is missing.'
Assert-Match $Workflow '--exit-code 1' 'Vulnerability scanner must fail the job when findings meet the gate.'
Assert-Match $Workflow 'anchore/syft@sha256:[0-9a-f]{64}' 'Syft must be pinned by immutable container digest.'
Assert-Match $Workflow 'aquasec/trivy@sha256:[0-9a-f]{64}' 'Trivy must be pinned by immutable container digest.'
Assert-Match $Workflow 'cosign sign-blob --yes' 'Keyless checksum signing is missing.'
Assert-Match $Workflow 'cosign sign --yes' 'Keyless server image signing is missing.'
Assert-Match $Workflow 'actions/attest@[0-9a-f]{40}' 'GitHub build provenance attestation is missing or not SHA-pinned.'
Assert-Match $Workflow 'gh release create' 'GitHub Release publication step is missing.'
Assert-Match $Workflow '--verify-tag' 'GitHub Release must verify the existing Git tag.'
Assert-Match $Workflow 'retention-days:\s*90' 'Rollback-capable Actions artifact retention must be 90 days.'
Assert-True ($Workflow -notmatch 'releases/latest') 'Previous release resolution must not use GitHub /releases/latest because it ignores prereleases.'
Assert-Match $Workflow 'gh api --paginate --slurp' 'Previous release resolution must enumerate all published GitHub Releases, including prereleases.'
Assert-Match $Workflow 'release_contract\.py previous-release' 'Previous release selection must use the tested SemVer release resolver.'
Assert-Match $Contract 'previous formal release .* has no retained rollback assets' 'Previous GitHub Release asset retention guard is missing.'
Assert-Match $Workflow 'previous rollback image is missing' 'Previous GHCR rollback image retention guard is missing.'
Assert-Match $Workflow 'server-\$\{component\}-linux-amd64' 'Versioned linux/amd64 server artifacts are missing.'
Assert-Match $Workflow 'windows-x64\.zip' 'Versioned Windows x64 artifact is missing.'
Assert-Match $Workflow 'android-\$\{abi\}\.apk' 'Versioned per-ABI Android artifacts are missing.'
Assert-Match $Workflow 'web-any\.tar\.gz' 'Versioned Web artifact is missing.'
Assert-Match $Workflow '(?ms)assemble-attest-and-sign:.*?needs:.*?- build-ios' 'Assemble/provenance job must depend on build-ios.'
Assert-Match $Contract 'ios-arm64' 'Release metadata platform classifier must recognize iOS IPA.'
Assert-True ($Workflow -notmatch '(?m)^\s*continue-on-error:\s*true\s*$') 'Release gates must not use continue-on-error: true.'
Assert-True ($Workflow -notmatch 'if:\s*\$\{\{\s*always\(\)') 'Release publication DAG must not bypass failed dependencies with always().'
Assert-True ($Workflow -notmatch '(?i)gitleaks\s+(git|dir|detect)') 'U25 must consume U06 Secret Scan evidence instead of reimplementing Gitleaks.'
Assert-True ($Workflow -notmatch '(?i):latest(?:\s|''|"|$)') 'Formal release workflow must not use a mutable :latest image/release identifier.'

$RemoteUses = [regex]::Matches($Workflow, '(?m)^\s*uses:\s*([^\s#]+)')
Assert-True ($RemoteUses.Count -gt 0) 'Release workflow contains no actions to validate.'
foreach ($Match in $RemoteUses) {
    $Use = $Match.Groups[1].Value
    if ($Use.StartsWith('./')) {
        continue
    }
    Assert-True ($Use -match '@[0-9a-f]{40}$') "GitHub Action is not pinned to an immutable 40-hex commit: $Use"
}

Assert-True ([int]$Retention.actionsArtifactRetentionDays -eq 90) 'Retention policy must keep Actions release evidence for 90 days.'
Assert-True ([int]$Retention.minimumFormalReleasesToRetain -ge 2) 'Rollback policy must retain at least current + previous formal release.'
Assert-True ($Retention.rollback.automaticDownMigration -eq $false) 'Release rollback policy must never enable automatic down migration.'

$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("dd-release-contract-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
try {
    $Repo = Join-Path $TempRoot 'repo'
    New-Item -ItemType Directory -Path $Repo -Force | Out-Null
    & git -C $Repo init -b master | Out-Null
    & git -C $Repo config user.email 'release-contract@example.invalid'
    & git -C $Repo config user.name 'DD Release Contract Test'
    Set-Content -LiteralPath (Join-Path $Repo 'payload.txt') -Value 'release fixture' -Encoding UTF8
    @"
# Changelog

## [1.2.3] - 2026-08-12

### Added
- Release fixture.
"@ | Set-Content -LiteralPath (Join-Path $Repo 'CHANGELOG.md') -Encoding UTF8
    & git -C $Repo add payload.txt CHANGELOG.md
    & git -C $Repo commit -m 'test: release fixture' | Out-Null
    & git -C $Repo tag v1.2.3

    & python $ContractPath validate --repo $Repo --tag v1.2.3 --changelog (Join-Path $Repo 'CHANGELOG.md') | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Clean exact-tag release fixture was rejected.'
    }

    Invoke-ExpectedFailure -Message 'Non-SemVer tag was accepted.' -Action {
        & python $ContractPath validate --repo $Repo --tag release-1.2.3 --changelog (Join-Path $Repo 'CHANGELOG.md') | Out-Null
    }

    Set-Content -LiteralPath (Join-Path $Repo 'dirty.txt') -Value 'uncommitted' -Encoding UTF8
    Invoke-ExpectedFailure -Message 'Dirty release source tree was accepted.' -Action {
        & python $ContractPath validate --repo $Repo --tag v1.2.3 --changelog (Join-Path $Repo 'CHANGELOG.md') | Out-Null
    }
    Remove-Item -LiteralPath (Join-Path $Repo 'dirty.txt') -Force

    $Artifacts = Join-Path $TempRoot 'artifacts'
    New-Item -ItemType Directory -Path $Artifacts -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Artifacts 'DD-v1.2.3-web-any.tar.gz') -Value 'web' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Artifacts 'DD-v1.2.3-server-api-linux-amd64.tar') -Value 'server' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Artifacts 'DD-v1.2.3-ios-arm64.ipa') -Value 'ios-release-fixture' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Artifacts 'DD-v1.2.3-ios-native-deps.zip') -Value 'ios-native-evidence' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Artifacts 'DD-v1.2.3-ios-codemagic-resolved.spdx.json') -Value '{"sbom":"codemagic"}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Artifacts 'DD-v1.2.3-ios-codemagic-resolved.trivy.json') -Value '{"scan":"codemagic"}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Artifacts 'DD-v1.2.3-ios-github-verified.spdx.json') -Value '{"sbom":"github"}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Artifacts 'DD-v1.2.3-ios-github-verified.trivy.json') -Value '{"scan":"github"}' -Encoding UTF8

    $Head = ((& git -C $Repo rev-parse HEAD) | Select-Object -Last 1).Trim()
    $CommitDate = ((& git -C $Repo show -s --format=%cI HEAD) | Select-Object -Last 1).Trim()
    $MetadataPath = Join-Path $Artifacts 'DD-v1.2.3-release-metadata.json'
    $ProvenancePath = Join-Path $Artifacts 'DD-v1.2.3-provenance.json'
    & python $ContractPath metadata `
        --root $Artifacts `
        --output $MetadataPath `
        --version 1.2.3 `
        --tag v1.2.3 `
        --commit $Head `
        --commit-date $CommitDate `
        --commit-count 1 `
        --previous-release v1.2.2 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Release metadata generation failed.'
    }
    & python $ContractPath provenance `
        --root $Artifacts `
        --output $ProvenancePath `
        --metadata $MetadataPath `
        --repository example/dd `
        --workflow-run-url 'https://github.com/example/dd/actions/runs/12345' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Release provenance generation failed.'
    }
    $Metadata = Get-Content -LiteralPath $MetadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $Provenance = Get-Content -LiteralPath $ProvenancePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($Metadata.releaseVersion -eq '1.2.3') 'Release metadata lost the SemVer version.'
    Assert-True ($Metadata.gitTag -eq 'v1.2.3') 'Release metadata lost the Git tag.'
    Assert-True ($Metadata.gitCommit -eq $Head) 'Release metadata lost the Git commit SHA.'
    Assert-True ($Metadata.previousFormalRelease -eq 'v1.2.2') 'Release metadata lost previous-release rollback evidence.'
    Assert-True ($Provenance.predicate.gitCommit -eq $Head) 'Provenance does not link to the Git commit SHA.'
    Assert-True ($Provenance.predicate.gitTag -eq 'v1.2.3') 'Provenance does not link to the formal Git tag.'
    Assert-True ($Provenance.predicate.releaseVersion -eq '1.2.3') 'Provenance does not link to the release version.'
    Assert-True ($Provenance.predicate.workflowRun -eq 'https://github.com/example/dd/actions/runs/12345') 'Provenance does not link to the workflow run.'
    Assert-True (@($Provenance.subject).Count -ge 8) 'Provenance must contain all iOS release/security subjects.'
    foreach ($IosArtifact in @(
        'DD-v1.2.3-ios-arm64.ipa',
        'DD-v1.2.3-ios-native-deps.zip',
        'DD-v1.2.3-ios-codemagic-resolved.spdx.json',
        'DD-v1.2.3-ios-codemagic-resolved.trivy.json',
        'DD-v1.2.3-ios-github-verified.spdx.json',
        'DD-v1.2.3-ios-github-verified.trivy.json'
    )) {
        Assert-True (@($Metadata.artifacts | Where-Object { $_.name -eq $IosArtifact }).Count -eq 1) "Release metadata must include $IosArtifact."
        Assert-True (@($Provenance.subject | Where-Object { $_.name -eq $IosArtifact }).Count -eq 1) "Provenance must include $IosArtifact."
    }

    $Manifest = Join-Path $Artifacts 'DD-v1.2.3-SHA256SUMS.txt'
    & python $ContractPath checksums --root $Artifacts --output $Manifest | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Checksum generation failed.'
    }
    & python $ContractPath verify-checksums --root $Artifacts --manifest $Manifest | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Fresh checksum manifest did not verify.'
    }
    $ManifestText = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8
    Assert-Match $ManifestText 'DD-v1\.2\.3-ios-arm64\.ipa' 'SHA256SUMS must include the iOS IPA.'
    Assert-Match $ManifestText 'DD-v1\.2\.3-ios-native-deps\.zip' 'SHA256SUMS must include iOS native dependency evidence.'
    Assert-Match $ManifestText 'DD-v1\.2\.3-ios-codemagic-resolved\.spdx\.json' 'SHA256SUMS must include Codemagic iOS SBOM.'
    Assert-Match $ManifestText 'DD-v1\.2\.3-ios-codemagic-resolved\.trivy\.json' 'SHA256SUMS must include Codemagic iOS Trivy report.'
    Assert-Match $ManifestText 'DD-v1\.2\.3-ios-github-verified\.spdx\.json' 'SHA256SUMS must include GitHub-verified iOS SBOM.'
    Assert-Match $ManifestText 'DD-v1\.2\.3-ios-github-verified\.trivy\.json' 'SHA256SUMS must include GitHub-verified iOS Trivy report.'
    Add-Content -LiteralPath (Join-Path $Artifacts 'DD-v1.2.3-web-any.tar.gz') -Value 'tampered' -Encoding UTF8
    Invoke-ExpectedFailure -Message 'Tampered release artifact passed checksum verification.' -Action {
        & python $ContractPath verify-checksums --root $Artifacts --manifest $Manifest | Out-Null
    }
}
finally {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[release-pipeline] PASS: tag-only trigger, fail-closed DAG, signing contracts, pinned scanners/actions, checksum tamper detection, dirty-tree rejection, provenance/retention contracts verified."
