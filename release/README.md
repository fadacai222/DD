# DD Formal Release Contract

`release.yml` is the only formal publication path added by U25. It is intentionally fail-closed and tag-driven.

## Version and tag

Formal releases use Semantic Versioning:

```text
vMAJOR.MINOR.PATCH
vMAJOR.MINOR.PATCH-prerelease
```

Examples: `v0.4.0`, `v0.4.1-rc.1`.

The tag is the source of truth. The workflow rejects:

- non-SemVer tags;
- a tag that does not point at the checked-out commit;
- a tag whose commit is not the current `origin/master` HEAD;
- a dirty source tree;
- a version without a dated `CHANGELOG.md` entry.

Flutter `build-number` is derived from the positive Git commit count, so native package metadata is reproducible for the same release commit. Android/Windows use the full SemVer as their release version. Apple requires `CFBundleShortVersionString` to be a numeric marketing version, so iOS deterministically maps both stable and prerelease tags to the SemVer core (`v1.2.3-rc.1` -> `1.2.3`) and uses the Git commit count as `CFBundleVersion`; the tuple `(CFBundleShortVersionString, CFBundleVersion, Git tag)` remains one-to-one with the formal U25 release. Server binaries receive the release version through linker flags; server images also carry OCI version/revision/created/source labels. The downloadable release metadata additionally records the full SHA, tag, version, commit date/count, workflow URL and artifact hashes.

## Fail-closed gate DAG

```text
v* tag push
  -> verify-source-and-upstream-gates
       -> exact tag / SemVer / changelog / clean tree / origin-master SHA
       -> exact-SHA successful master push run of ci.yml
       -> exact-SHA successful master push run of secret-scan.yml
  -> dependency-vulnerability-scan (Trivy HIGH/CRITICAL => fail)
  -> build-web ---------------------------\
  -> build-android [release-signing env] --+-> assemble-attest-and-sign
  -> build-windows [release-signing env] --+      -> SHA-256 manifest + verify
  -> build-ios [release-signing env -> Codemagic signed IPA] --+
  -> build-server-images -------------------------------/     -> SPDX SBOMs / Trivy reports
                                                  -> Sigstore keyless checksum signature
                                                  -> GitHub Artifact Attestation
     -> production-release [production-release env approval]
          -> reverify tag/checksum/Sigstore evidence
          -> push immutable GHCR api/worker/migrate version tags
          -> keyless-sign image digests + image attestations
          -> create GitHub Release from the existing verified tag
```

No release job uses `continue-on-error: true` or `always()` to bypass failed dependencies. U06 is not reimplemented: U25 verifies that the existing full-history `secret-scan.yml` master push run succeeded for the exact release SHA.

## GitHub Environments and owner-provided signing material

Create these Environments before attempting a formal native release.

### `release-signing`

Secrets:

```text
DD_ANDROID_KEYSTORE_BASE64
DD_ANDROID_KEYSTORE_PASSWORD
DD_ANDROID_KEY_ALIAS
DD_ANDROID_KEY_PASSWORD
DD_WINDOWS_CODESIGN_PFX_BASE64
DD_WINDOWS_CODESIGN_PFX_PASSWORD
DD_CODEMAGIC_API_TOKEN
```

Environment variables:

```text
DD_ANDROID_CERT_SHA256
DD_WINDOWS_CERT_THUMBPRINT
DD_WINDOWS_TIMESTAMP_URL
DD_CODEMAGIC_APP_ID
```

`DD_ANDROID_CERT_SHA256` is the expected SHA-256 signing-certificate digest, not a secret. `DD_WINDOWS_CERT_THUMBPRINT` is the expected certificate thumbprint. `DD_WINDOWS_TIMESTAMP_URL` must be an HTTPS RFC3161 timestamp endpoint. `DD_CODEMAGIC_API_TOKEN` only authorizes the GitHub release job to trigger/read the Codemagic build; Apple signing material remains exclusively in Codemagic. `DD_CODEMAGIC_APP_ID` identifies the Codemagic application.

The workflow writes decoded JKS/PFX material only to the hosted runner temporary directory. Nothing is written to the repository. Missing signing material, malformed fingerprints, or signer mismatch is a hard failure. Formal Android builds explicitly set `DD_ANDROID_REQUIRE_PROD_SIGNING=true`; therefore the debug signing fallback retained for ordinary CI smoke builds cannot be used by the formal release job.

iOS uses Codemagic workflow `ios-signed-release`. Apple integration `DD_APP_STORE_CONNECT` holds the App Store Connect API key and obtains the App Store distribution certificate/provisioning profile; protected Codemagic variable group `dd_ios_release` must provide `DD_IOS_BUNDLE_ID` and `DD_IOS_TEAM_ID`. GitHub never receives `.p8`, `.p12`, `.mobileprovision`, Apple private keys, certificate passwords, or Apple ID passwords. Codemagic verifies `codesign`, embedded provisioning identity, Bundle ID, Team ID and Flutter version/build metadata before exposing the IPA. Missing Apple integration/signing identity fails closed.

### `production-release`

Configure **Required reviewers** in GitHub Environment protection rules. The repository can bind a job to the Environment, but the actual reviewer list/policy lives in GitHub settings and therefore requires a project owner to configure and verify it.

Recommended owner settings:

- at least one required reviewer who is not the release initiator;
- prevent self-review where the GitHub plan supports it;
- deployment branch/tag protection limited to formal release tags;
- keep Environment secrets scoped to the narrowest Environment that needs them.

Until these settings and the real native signing certificates exist, U25 code can be auto-verified but a production-native release remains `SECRET/HUMAN-REQUIRED`.

## Formal artifacts

For tag `vX.Y.Z`:

```text
DD-vX.Y.Z-windows-x64.zip
DD-vX.Y.Z-ios-arm64.ipa
DD-vX.Y.Z-ios.spdx.json
DD-vX.Y.Z-ios-native-deps.zip
DD-vX.Y.Z-android-arm64-v8a.apk
DD-vX.Y.Z-android-armeabi-v7a.apk
DD-vX.Y.Z-android-x86_64.apk
DD-vX.Y.Z-web-any.tar.gz
DD-vX.Y.Z-server-api-linux-amd64.tar
DD-vX.Y.Z-server-worker-linux-amd64.tar
DD-vX.Y.Z-server-migrate-linux-amd64.tar
DD-vX.Y.Z-client.spdx.json
DD-vX.Y.Z-server-api-linux-amd64.spdx.json
DD-vX.Y.Z-server-worker-linux-amd64.spdx.json
DD-vX.Y.Z-server-migrate-linux-amd64.spdx.json
DD-vX.Y.Z-dependencies.trivy.json
DD-vX.Y.Z-server-api-linux-amd64.trivy.json
DD-vX.Y.Z-server-worker-linux-amd64.trivy.json
DD-vX.Y.Z-server-migrate-linux-amd64.trivy.json
DD-vX.Y.Z-upstream-gates.json
DD-vX.Y.Z-release-metadata.json
DD-vX.Y.Z-provenance.json
DD-vX.Y.Z-SHA256SUMS.txt
DD-vX.Y.Z-SHA256SUMS.sigstore.json
```

The server image archives are also published after production approval to immutable version tags:

```text
ghcr.io/<owner>/<repo>-api:vX.Y.Z
ghcr.io/<owner>/<repo>-worker:vX.Y.Z
ghcr.io/<owner>/<repo>-migrate:vX.Y.Z
```

The workflow records the pushed image digests and signs/attests the digest references; it never relies on `latest` as the formal release identity.

## Verification

Release assets are integrity-linked by `DD-<tag>-SHA256SUMS.txt`. The manifest is itself keyless-signed using GitHub OIDC/Sigstore and is verified again after the production Environment approval.

GitHub Artifact Attestations provide the cryptographically signed build provenance. `DD-<tag>-provenance.json` is a downloadable human/machine-readable mapping of artifact digest -> release version -> Git tag -> commit -> workflow run/build platforms; it is descriptive and is not presented as a substitute for the GitHub-signed attestation.

A consumer should verify, in this order:

1. GitHub Release tag/commit identity.
2. GitHub Artifact Attestation for downloaded artifacts.
3. Sigstore bundle for `SHA256SUMS.txt`.
4. SHA-256 of the actual artifact against `SHA256SUMS.txt`.
5. Native platform signature where applicable (Android signer certificate / Windows Authenticode / iOS Apple Distribution + provisioning identity).
6. Trivy report and SPDX SBOM corresponding to the release.

## Rollback retention and U23 compatibility

`retention-policy.json` requires at least the current and immediately previous formal release to remain available. The previous formal release is resolved from all published GitHub Releases, including prereleases; drafts and non-DD/non-SemVer tags are ignored, and the most recently published valid release before the pending tag is selected. This means `v0.5.0-rc.2` correctly retains/verifies `v0.5.0-rc.1`, while a following `v0.5.0` retains/verifies `v0.5.0-rc.2`. Actions build evidence is retained for 90 days; GitHub Release assets and immutable versioned GHCR image tags are not automatically pruned by this workflow.

Rollback follows U23 and never invents a database down migration:

```text
previous application accepts newer schema
  -> application-only rollback may use previous immutable artifacts/images

previous application rejects newer schema
  -> keep old application stopped
  -> restore the verified pre-upgrade DB + object-storage recovery point
  -> restart the previous immutable release
```

`migrate down` is not part of the formal release or rollback workflow.
