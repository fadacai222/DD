# Changelog

DD follows Semantic Versioning for formal releases. Formal Git tags use the exact form `vMAJOR.MINOR.PATCH` with an optional SemVer pre-release suffix, for example `v0.4.0-rc.1`.

## [Unreleased]

No release notes yet.

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
