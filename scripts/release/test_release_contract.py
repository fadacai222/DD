from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

import release_contract
import verify_github_gates


class ReleaseContractTests(unittest.TestCase):
    @staticmethod
    def _release(
        tag: str,
        published_at: str,
        *,
        draft: bool = False,
        prerelease: bool = False,
        asset_count: int = 1,
    ) -> dict[str, object]:
        return {
            "tag_name": tag,
            "published_at": published_at,
            "draft": draft,
            "prerelease": prerelease,
            "assets": [{"name": f"asset-{index}"} for index in range(asset_count)],
        }

    def test_semver_rejects_build_metadata_and_non_version_tags(self) -> None:
        self.assertEqual(release_contract.version_from_tag("v1.2.3"), "1.2.3")
        self.assertEqual(release_contract.version_from_tag("v1.2.3-rc.1"), "1.2.3-rc.1")
        with self.assertRaises(release_contract.ReleaseContractError):
            release_contract.version_from_tag("release-1.2.3")
        with self.assertRaises(release_contract.ReleaseContractError):
            release_contract.version_from_tag("v1.2.3+build.7")

    def test_checksum_verification_detects_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            artifact = root / "DD-v1.2.3-web-any.tar.gz"
            manifest = root / "DD-v1.2.3-SHA256SUMS.txt"
            artifact.write_bytes(b"original")
            release_contract.write_checksums(root, manifest)
            self.assertEqual(release_contract.verify_checksums(root, manifest), 1)
            artifact.write_bytes(b"tampered")
            with self.assertRaises(release_contract.ReleaseContractError):
                release_contract.verify_checksums(root, manifest)

    def test_previous_formal_release_stable_to_stable(self) -> None:
        releases = [
            self._release("v0.4.0", "2026-08-10T10:00:00Z"),
            self._release("v0.4.1", "2026-08-11T10:00:00Z"),
        ]
        previous = release_contract.resolve_previous_formal_release(releases, "v0.5.0")
        self.assertEqual(previous["tag"], "v0.4.1")

    def test_previous_formal_release_stable_to_rc1(self) -> None:
        releases = [self._release("v0.4.1", "2026-08-11T10:00:00Z")]
        previous = release_contract.resolve_previous_formal_release(releases, "v0.5.0-rc.1")
        self.assertEqual(previous["tag"], "v0.4.1")

    def test_previous_formal_release_rc1_to_rc2(self) -> None:
        releases = [
            [self._release("v0.5.0-rc.1", "2026-08-12T08:00:00Z", prerelease=True)],
            [self._release("v0.4.1", "2026-08-11T10:00:00Z")],
        ]
        previous = release_contract.resolve_previous_formal_release(releases, "v0.5.0-rc.2")
        self.assertEqual(previous["tag"], "v0.5.0-rc.1")

    def test_previous_formal_release_rc2_to_stable(self) -> None:
        releases = [
            self._release("v0.5.0-rc.2", "2026-08-12T09:00:00Z", prerelease=True),
            self._release("v0.5.0-rc.1", "2026-08-12T08:00:00Z", prerelease=True),
            self._release("v0.4.1", "2026-08-11T10:00:00Z"),
        ]
        previous = release_contract.resolve_previous_formal_release(releases, "v0.5.0")
        self.assertEqual(previous["tag"], "v0.5.0-rc.2")

    def test_previous_formal_release_ignores_draft(self) -> None:
        releases = [
            self._release("v0.5.0-rc.2", "2026-08-12T09:00:00Z", draft=True, prerelease=True),
            self._release("v0.5.0-rc.1", "2026-08-12T08:00:00Z", prerelease=True),
        ]
        previous = release_contract.resolve_previous_formal_release(releases, "v0.5.0")
        self.assertEqual(previous["tag"], "v0.5.0-rc.1")

    def test_previous_formal_release_ignores_unrelated_and_non_semver(self) -> None:
        releases = [
            self._release("nightly", "2026-08-12T11:00:00Z"),
            self._release("release-0.5.0", "2026-08-12T10:00:00Z"),
            self._release("v0.5", "2026-08-12T09:00:00Z"),
            self._release("v0.4.1", "2026-08-11T10:00:00Z"),
        ]
        previous = release_contract.resolve_previous_formal_release(releases, "v0.5.0")
        self.assertEqual(previous["tag"], "v0.4.1")

    def test_previous_formal_release_none_when_no_formal_release_exists(self) -> None:
        releases = [
            self._release("nightly", "2026-08-12T11:00:00Z"),
            self._release("v0.5.0-rc.1", "2026-08-12T10:00:00Z", draft=True, prerelease=True),
        ]
        previous = release_contract.resolve_previous_formal_release(releases, "v0.5.0-rc.1")
        self.assertEqual(previous["tag"], "NONE")
        self.assertEqual(previous["assetCount"], 0)

    def test_previous_formal_release_without_assets_is_rejected(self) -> None:
        releases = [self._release("v0.4.1", "2026-08-11T10:00:00Z", asset_count=0)]
        previous = release_contract.resolve_previous_formal_release(releases, "v0.5.0")
        with self.assertRaises(release_contract.ReleaseContractError):
            release_contract.ensure_previous_release_assets(previous)


class UpstreamGateTests(unittest.TestCase):
    def test_branch_head_must_match_release_sha(self) -> None:
        release_sha = "a" * 40
        with mock.patch.object(
            verify_github_gates,
            "api_json",
            return_value={
                "ref": "refs/heads/master",
                "object": {"sha": "b" * 40},
            },
        ):
            with self.assertRaises(verify_github_gates.GateError):
                verify_github_gates.verify_branch_head(
                    repository="example/dd",
                    branch="master",
                    sha=release_sha,
                    token="test-token",
                )

    def test_failed_ci_run_is_not_accepted(self) -> None:
        release_sha = "a" * 40
        with mock.patch.object(
            verify_github_gates,
            "api_json",
            return_value={
                "workflow_runs": [
                    {
                        "id": 1,
                        "run_number": 10,
                        "run_attempt": 1,
                        "html_url": "https://github.com/example/dd/actions/runs/1",
                        "head_sha": release_sha,
                        "head_branch": "master",
                        "event": "push",
                        "conclusion": "failure",
                    }
                ]
            },
        ):
            with self.assertRaises(verify_github_gates.GateError):
                verify_github_gates.verify_workflow(
                    repository="example/dd",
                    workflow="ci.yml",
                    sha=release_sha,
                    branch="master",
                    token="test-token",
                )

    def test_failed_secret_scan_run_is_not_accepted(self) -> None:
        release_sha = "a" * 40
        with mock.patch.object(
            verify_github_gates,
            "api_json",
            return_value={
                "workflow_runs": [
                    {
                        "id": 2,
                        "run_number": 11,
                        "run_attempt": 1,
                        "html_url": "https://github.com/example/dd/actions/runs/2",
                        "head_sha": release_sha,
                        "head_branch": "master",
                        "event": "push",
                        "conclusion": "cancelled",
                    }
                ]
            },
        ):
            with self.assertRaises(verify_github_gates.GateError):
                verify_github_gates.verify_workflow(
                    repository="example/dd",
                    workflow="secret-scan.yml",
                    sha=release_sha,
                    branch="master",
                    token="test-token",
                )

    def test_only_successful_master_push_for_exact_sha_is_accepted(self) -> None:
        release_sha = "a" * 40
        with mock.patch.object(
            verify_github_gates,
            "api_json",
            return_value={
                "workflow_runs": [
                    {
                        "id": 3,
                        "run_number": 12,
                        "run_attempt": 1,
                        "html_url": "https://github.com/example/dd/actions/runs/3",
                        "head_sha": release_sha,
                        "head_branch": "master",
                        "event": "pull_request",
                        "conclusion": "success",
                    },
                    {
                        "id": 4,
                        "run_number": 13,
                        "run_attempt": 1,
                        "html_url": "https://github.com/example/dd/actions/runs/4",
                        "head_sha": release_sha,
                        "head_branch": "master",
                        "event": "push",
                        "conclusion": "success",
                    },
                ]
            },
        ):
            evidence = verify_github_gates.verify_workflow(
                repository="example/dd",
                workflow="ci.yml",
                sha=release_sha,
                branch="master",
                token="test-token",
            )
        self.assertEqual(evidence["runId"], 4)
        self.assertEqual(evidence["event"], "push")
        self.assertEqual(evidence["conclusion"], "success")


if __name__ == "__main__":
    unittest.main()
