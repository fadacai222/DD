#!/usr/bin/env python3
"""Fail-closed validation for resolved iOS native dependency scan evidence."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


class NativeScanError(RuntimeError):
    pass


RESOLVED_LOCK_BASENAMES = {"Package.resolved", "Podfile.lock"}


def resolved_lockfiles(root: Path) -> list[Path]:
    if not root.is_dir():
        raise NativeScanError(f"native evidence directory is missing: {root}")
    locks = sorted(
        path
        for path in root.rglob("*")
        if path.is_file()
        and path.name in RESOLVED_LOCK_BASENAMES
        and path.stat().st_size > 0
    )
    if not locks:
        raise NativeScanError(
            "native evidence must contain at least one non-empty Package.resolved or Podfile.lock"
        )
    return locks


def validate_trivy_report(report: Path) -> int:
    try:
        payload = json.loads(report.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise NativeScanError(f"invalid Trivy JSON report: {exc}") from exc
    results = payload.get("Results") if isinstance(payload, dict) else None
    if not isinstance(results, list) or not results:
        raise NativeScanError("Trivy report has no Results")

    package_count = 0
    native_targets = 0
    for result in results:
        if not isinstance(result, dict):
            continue
        target = result.get("Target")
        if not isinstance(target, str) or Path(target).name not in RESOLVED_LOCK_BASENAMES:
            continue
        native_targets += 1
        packages = result.get("Packages")
        if not isinstance(packages, list) or not packages:
            raise NativeScanError(f"Trivy native target has no packages: {target}")
        package_count += len(packages)

    if native_targets == 0:
        raise NativeScanError("Trivy report contains no Package.resolved or Podfile.lock target")
    if package_count == 0:
        raise NativeScanError("Trivy report contains no resolved native packages")
    return package_count


def validate_spdx_report(report: Path) -> int:
    try:
        payload = json.loads(report.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise NativeScanError(f"invalid SPDX JSON report: {exc}") from exc
    packages = payload.get("packages") if isinstance(payload, dict) else None
    if not isinstance(packages, list) or not packages:
        raise NativeScanError("SPDX SBOM contains no packages")
    return len(packages)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    evidence = sub.add_parser("evidence")
    evidence.add_argument("--root", required=True)

    trivy = sub.add_parser("trivy")
    trivy.add_argument("--report", required=True)

    spdx = sub.add_parser("spdx")
    spdx.add_argument("--report", required=True)
    return parser


def main() -> int:
    try:
        args = build_parser().parse_args()
        if args.command == "evidence":
            locks = resolved_lockfiles(Path(args.root))
            print(f"validated {len(locks)} resolved native lockfile(s)")
        elif args.command == "trivy":
            count = validate_trivy_report(Path(args.report))
            print(f"validated {count} Trivy native package(s)")
        elif args.command == "spdx":
            count = validate_spdx_report(Path(args.report))
            print(f"validated {count} SPDX native package(s)")
        return 0
    except NativeScanError as exc:
        print(f"[ios-native-scan] ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
