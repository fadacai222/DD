# Changelog

DD follows Semantic Versioning for formal releases. Formal Git tags use the exact form `vMAJOR.MINOR.PATCH` with an optional SemVer pre-release suffix, for example `v0.4.0-rc.1`.

## [Unreleased]

### Added
- U30 iOS platform delivery code is now integrated locally: iOS 15.0 Runner foundation, Keychain-backed auth vault contract, APNs/FCM notification lifecycle, Files/Photos/camera/media bridges, QR lifecycle, LiveKit/CallKit/audio integration, and shared native-service registration/Xcode Sources wiring.
- Codemagic unsigned Release/archive validation plus signed App Store Connect delivery, resolved-native SBOM/vulnerability evidence, and GitHub release provenance integration.

### Changed
- Auth/Push account switching and logout now keep Push endpoint ownership fail-closed: ordinary `401/SESSION_EXPIRED` is not treated as device revocation, stale refresh completions are account/epoch isolated, and local Auth is only forgotten after endpoint deletion or authoritative device revocation is confirmed.
- CallKit answer/decline/cancel/end uses server-confirmed two-phase action completion; outgoing ringing cancellation maps to `hangup`, incoming decline maps to `reject`, and failed/timed-out actions no longer falsely succeed in the system UI.
- iOS media/file selection stays path/stream based for large media, and QR camera permission can recover after the user changes Camera access in iOS Settings.

### Validation
- Full-history Secret Scan is merge-aware: Git log options emit first-parent merge patches so merge commits are counted instead of being silently omitted while the commit-count guard remains fail closed.
- U30 integrated local gate: `dart analyze --fatal-infos` 0 issue; iOS/Push/Media/QR/Calls directed contracts 46/46; Flutter full suite 447 PASS / 5 SKIP; `go test ./...` and `go vet ./...` PASS; PostgreSQL 18.4 applied 33 migrations with Auth and Push lifecycle integration PASS; release/native-scan contracts and full-history Secret Scan PASS.
- Real macOS/Xcode compile/archive, Apple/Firebase signing material, App Store Connect/TestFlight processing, APNs device delivery and iPhone/iPad acceptance remain cloud/secret/human pending.

## [0.4.0] - 2026-08-12

### Added
- Multi-platform DD client and server baseline covering the current messaging, groups, calls, Moments, QR, Push, Admin/Governance, Data Rights, and production self-hosting feature set.
- Production self-hosting, backup/restore, forward-only upgrade/rollback compatibility checks, and observability/alerting foundations.
- Formal release engineering with exact-SHA CI/Secret Scan evidence, production-signed native artifact contracts, SPDX SBOMs, vulnerability gates, SHA-256, Sigstore/GitHub provenance, production approval, and rollback retention evidence.

### Security
- Full-history Gitleaks blocking gate with Git worktree support, detector self-test, shallow/zero-commit/fatal Git false-green protection, and narrow allowlists.
- Explicit PostgreSQL integration gates for Moments and QR lifecycle/migration coverage.

### Known validation status
- Real Android/iOS Push delivery, public TURN across carrier/NAT combinations, production-scale RPO/RTO, and remaining real-device/UI acceptance still require human/production-environment evidence before Stable 1.0.
