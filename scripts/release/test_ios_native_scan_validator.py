from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import ios_native_scan_validator as validator


class NativeEvidenceTests(unittest.TestCase):
    def test_package_swift_only_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "Package.swift").write_text("// context\n", encoding="utf-8")
            with self.assertRaises(validator.NativeScanError):
                validator.resolved_lockfiles(root)

    def test_pubspec_and_package_swift_still_fail(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "pubspec.lock").write_text("packages: {}\n", encoding="utf-8")
            (root / "Package.swift").write_text("// context\n", encoding="utf-8")
            with self.assertRaises(validator.NativeScanError):
                validator.resolved_lockfiles(root)

    def test_nonempty_package_resolved_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "ios" / "Runner.xcworkspace" / "xcshareddata" / "swiftpm" / "Package.resolved"
            path.parent.mkdir(parents=True)
            path.write_text('{"pins":[{"identity":"firebase"}]}\n', encoding="utf-8")
            self.assertEqual(validator.resolved_lockfiles(Path(temp)), [path])

    def test_nonempty_podfile_lock_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "ios" / "Podfile.lock"
            path.parent.mkdir(parents=True)
            path.write_text("PODS:\n  - FirebaseCore (1.0.0)\n", encoding="utf-8")
            self.assertEqual(validator.resolved_lockfiles(Path(temp)), [path])

    def test_flattened_package_resolved_is_not_lock_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "ios__Runner__Package.resolved").write_text('{"pins":[]}\n', encoding="utf-8")
            with self.assertRaises(validator.NativeScanError):
                validator.resolved_lockfiles(root)


class TrivyReportTests(unittest.TestCase):
    def _write(self, root: Path, payload: object) -> Path:
        path = root / "trivy.json"
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

    def test_empty_results_fail(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            report = self._write(Path(temp), {"Results": []})
            with self.assertRaises(validator.NativeScanError):
                validator.validate_trivy_report(report)

    def test_dart_only_result_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            report = self._write(Path(temp), {"Results": [{"Target": "pubspec.lock", "Packages": [{"Name": "foo"}]}]})
            with self.assertRaises(validator.NativeScanError):
                validator.validate_trivy_report(report)

    def test_native_target_without_packages_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            report = self._write(Path(temp), {"Results": [{"Target": "ios/swiftpm/Package.resolved", "Packages": []}]})
            with self.assertRaises(validator.NativeScanError):
                validator.validate_trivy_report(report)

    def test_native_target_with_packages_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            report = self._write(Path(temp), {"Results": [{"Target": "ios/swiftpm/Package.resolved", "Packages": [{"Name": "firebase-ios-sdk"}]}]})
            self.assertEqual(validator.validate_trivy_report(report), 1)


class SpdxReportTests(unittest.TestCase):
    def _write(self, root: Path, packages: list[object]) -> Path:
        path = root / "sbom.spdx.json"
        path.write_text(json.dumps({"spdxVersion": "SPDX-2.3", "packages": packages}), encoding="utf-8")
        return path

    def test_empty_spdx_packages_fail(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            report = self._write(Path(temp), [])
            with self.assertRaises(validator.NativeScanError):
                validator.validate_spdx_report(report)

    def test_native_spdx_packages_pass(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            report = self._write(Path(temp), [{"name": "firebase-ios-sdk", "SPDXID": "SPDXRef-Package"}])
            self.assertEqual(validator.validate_spdx_report(report), 1)


if __name__ == "__main__":
    unittest.main()
