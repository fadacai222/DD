#!/usr/bin/env python3
"""Fail-closed release contract helpers for DD.

No third-party Python packages are required.  The formal release workflow uses
this module for source/tag validation, deterministic release metadata,
checksums, and a human-readable provenance manifest.  GitHub's signed artifact
attestations remain the authoritative cryptographic provenance.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import sys
import zipfile
from datetime import datetime
from pathlib import Path
from typing import Iterable

SEMVER_RE = re.compile(
    r"^(0|[1-9]\d*)\."
    r"(0|[1-9]\d*)\."
    r"(0|[1-9]\d*)"
    r"(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?$"
)
TAG_RE = re.compile(r"^v(.+)$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class ReleaseContractError(RuntimeError):
    pass


def run_git(repo: Path, *args: str) -> str:
    proc = subprocess.run(
        ["git", "-C", str(repo), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip()
        raise ReleaseContractError(f"git {' '.join(args)} failed: {detail}")
    return proc.stdout.strip()


def validate_semver(version: str) -> None:
    if not SEMVER_RE.fullmatch(version):
        raise ReleaseContractError(
            "release version must be SemVer MAJOR.MINOR.PATCH with optional "
            "pre-release suffix; build metadata (+...) is intentionally not "
            "accepted because Docker tags must map 1:1 to Git tags"
        )


def ios_marketing_version(version: str) -> str:
    validate_semver(version)
    return version.split("-", 1)[0]


def version_from_tag(tag: str) -> str:
    match = TAG_RE.fullmatch(tag)
    if not match:
        raise ReleaseContractError("formal release tag must start with 'v'")
    version = match.group(1)
    validate_semver(version)
    if tag != f"v{version}":
        raise ReleaseContractError("release tag/version mapping is not canonical")
    return version


def _flatten_release_pages(payload: object) -> list[dict[str, object]]:
    if not isinstance(payload, list):
        raise ReleaseContractError("GitHub releases payload must be a JSON array")
    releases: list[dict[str, object]] = []
    for item in payload:
        if isinstance(item, list):
            releases.extend(_flatten_release_pages(item))
        elif isinstance(item, dict):
            releases.append(item)
        else:
            raise ReleaseContractError("GitHub releases payload contains a non-object entry")
    return releases


def _published_at(value: object, tag: str) -> datetime:
    if not isinstance(value, str) or not value.strip():
        raise ReleaseContractError(f"published formal release {tag} has no published_at timestamp")
    rendered = value.strip()
    if rendered.endswith("Z"):
        rendered = rendered[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(rendered)
    except ValueError as exc:
        raise ReleaseContractError(
            f"published formal release {tag} has invalid published_at timestamp: {value!r}"
        ) from exc
    if parsed.tzinfo is None:
        raise ReleaseContractError(
            f"published formal release {tag} published_at timestamp must include timezone"
        )
    return parsed


def resolve_previous_formal_release(
    releases_payload: object,
    current_tag: str,
) -> dict[str, object]:
    version_from_tag(current_tag)
    candidates: list[tuple[datetime, str, int, str]] = []
    for release in _flatten_release_pages(releases_payload):
        if release.get("draft") is True:
            continue
        tag = release.get("tag_name")
        if not isinstance(tag, str) or tag == current_tag:
            continue
        try:
            version_from_tag(tag)
        except ReleaseContractError:
            continue
        published_raw = release.get("published_at")
        if published_raw in (None, ""):
            continue
        published_at = _published_at(published_raw, tag)
        assets = release.get("assets")
        if not isinstance(assets, list):
            raise ReleaseContractError(
                f"published formal release {tag} has invalid assets metadata"
            )
        candidates.append((published_at, tag, len(assets), str(published_raw)))

    if not candidates:
        return {"tag": "NONE", "assetCount": 0, "publishedAt": None}

    _, tag, asset_count, published_raw = max(candidates, key=lambda item: item[0])
    return {
        "tag": tag,
        "assetCount": asset_count,
        "publishedAt": published_raw,
    }


def ensure_previous_release_assets(previous: dict[str, object]) -> None:
    tag = previous.get("tag")
    if tag == "NONE":
        return
    asset_count = previous.get("assetCount")
    if not isinstance(asset_count, int) or asset_count <= 0:
        raise ReleaseContractError(
            f"previous formal release {tag} has no retained rollback assets"
        )


def ensure_clean(repo: Path) -> None:
    status = run_git(repo, "status", "--porcelain=v1", "--untracked-files=all")
    if status:
        raise ReleaseContractError(
            "formal release source tree is dirty; commit or remove every staged, "
            "unstaged, and untracked file before building"
        )


def ensure_exact_tag(repo: Path, tag: str) -> None:
    tags_at_head = {
        line.strip()
        for line in run_git(repo, "tag", "--points-at", "HEAD").splitlines()
        if line.strip()
    }
    if tag not in tags_at_head:
        raise ReleaseContractError(
            f"formal release tag {tag!r} does not point at HEAD; tags at HEAD: "
            f"{sorted(tags_at_head)!r}"
        )
    tagged_sha = run_git(repo, "rev-list", "-n", "1", tag)
    head = run_git(repo, "rev-parse", "HEAD")
    if tagged_sha != head:
        raise ReleaseContractError("release tag does not resolve to HEAD")


def ensure_changelog(changelog: Path, version: str) -> None:
    if not changelog.is_file():
        raise ReleaseContractError(f"changelog is missing: {changelog}")
    text = changelog.read_text(encoding="utf-8")
    pattern = re.compile(
        rf"^## \[{re.escape(version)}\] - \d{{4}}-\d{{2}}-\d{{2}}\s*$",
        re.MULTILINE,
    )
    if not pattern.search(text):
        raise ReleaseContractError(
            f"CHANGELOG must contain a dated '## [{version}] - YYYY-MM-DD' entry"
        )


def git_facts(repo: Path) -> dict[str, object]:
    head = run_git(repo, "rev-parse", "HEAD")
    commit_count_raw = run_git(repo, "rev-list", "--count", "HEAD")
    try:
        commit_count = int(commit_count_raw)
    except ValueError as exc:
        raise ReleaseContractError("git commit count is not numeric") from exc
    if commit_count <= 0:
        raise ReleaseContractError("git commit count must be positive")
    commit_date = run_git(repo, "show", "-s", "--format=%cI", "HEAD")
    commit_epoch_raw = run_git(repo, "show", "-s", "--format=%ct", "HEAD")
    try:
        commit_epoch = int(commit_epoch_raw)
    except ValueError as exc:
        raise ReleaseContractError("git commit timestamp is not numeric") from exc
    return {
        "gitCommit": head,
        "gitCommitCount": commit_count,
        "gitCommitDate": commit_date,
        "sourceDateEpoch": commit_epoch,
    }


def write_github_outputs(path: Path, values: dict[str, object]) -> None:
    with path.open("a", encoding="utf-8", newline="\n") as handle:
        for key, value in values.items():
            rendered = str(value).lower() if isinstance(value, bool) else str(value)
            handle.write(f"{key}={rendered}\n")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def iter_release_files(root: Path, excluded: set[Path]) -> Iterable[Path]:
    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        if not path.is_file():
            continue
        resolved = path.resolve()
        if resolved in excluded:
            continue
        yield path


def write_checksums(root: Path, output: Path) -> int:
    root = root.resolve()
    output = output.resolve()
    if not root.is_dir():
        raise ReleaseContractError(f"artifact root does not exist: {root}")
    excluded = {output}
    files = list(iter_release_files(root, excluded))
    if not files:
        raise ReleaseContractError("refusing to create an empty checksum manifest")
    lines: list[str] = []
    for path in files:
        relative = path.resolve().relative_to(root).as_posix()
        if "\n" in relative or "\r" in relative:
            raise ReleaseContractError("artifact filename contains a newline")
        lines.append(f"{sha256_file(path)}  {relative}")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    return len(lines)


def parse_checksum_manifest(root: Path, manifest: Path) -> list[tuple[str, Path]]:
    root = root.resolve()
    manifest = manifest.resolve()
    if not manifest.is_file():
        raise ReleaseContractError(f"checksum manifest is missing: {manifest}")
    records: list[tuple[str, Path]] = []
    seen: set[str] = set()
    for line_number, raw in enumerate(manifest.read_text(encoding="utf-8").splitlines(), 1):
        if not raw.strip():
            continue
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", raw)
        if not match:
            raise ReleaseContractError(f"invalid checksum line {line_number}")
        digest, relative = match.groups()
        if relative in seen:
            raise ReleaseContractError(f"duplicate checksum entry: {relative}")
        seen.add(relative)
        candidate = (root / Path(relative)).resolve()
        try:
            candidate.relative_to(root)
        except ValueError as exc:
            raise ReleaseContractError(f"checksum path escapes artifact root: {relative}") from exc
        records.append((digest, candidate))
    if not records:
        raise ReleaseContractError("checksum manifest has no entries")
    return records


def verify_checksums(root: Path, manifest: Path) -> int:
    records = parse_checksum_manifest(root, manifest)
    for expected, path in records:
        if not path.is_file():
            raise ReleaseContractError(f"checksummed artifact is missing: {path}")
        actual = sha256_file(path)
        if actual != expected:
            raise ReleaseContractError(
                f"checksum mismatch for {path.name}: expected {expected}, got {actual}"
            )
    return len(records)


def validate_ios_ipa_shape(ipa: Path, version: str, build_number: int) -> None:
    validate_semver(version)
    if build_number <= 0:
        raise ReleaseContractError("iOS build number must be positive")
    if not ipa.is_file() or ipa.stat().st_size == 0:
        raise ReleaseContractError(f"iOS IPA is missing: {ipa}")
    try:
        with zipfile.ZipFile(ipa) as archive:
            names = archive.namelist()
            apps = sorted({name.split("/")[1] for name in names if re.match(r"^Payload/[^/]+\.app/", name)})
            if len(apps) != 1:
                raise ReleaseContractError("iOS IPA must contain exactly one top-level .app")
            app = apps[0]
            prefix = f"Payload/{app}/"
            info_name = prefix + "Info.plist"
            profile_name = prefix + "embedded.mobileprovision"
            signature_name = prefix + "_CodeSignature/CodeResources"
            for required in (info_name, profile_name, signature_name):
                if required not in names:
                    raise ReleaseContractError(f"production iOS IPA is unsigned/incomplete: missing {required}")
            info = plistlib.loads(archive.read(info_name))
    except (zipfile.BadZipFile, plistlib.InvalidFileException, KeyError) as exc:
        raise ReleaseContractError(f"invalid iOS IPA structure: {exc}") from exc
    actual_version = str(info.get("CFBundleShortVersionString", ""))
    actual_build = str(info.get("CFBundleVersion", ""))
    if actual_version != version:
        raise ReleaseContractError(
            f"iOS CFBundleShortVersionString mismatch: expected {version}, got {actual_version or 'EMPTY'}"
        )
    if actual_build != str(build_number):
        raise ReleaseContractError(
            f"iOS CFBundleVersion mismatch: expected {build_number}, got {actual_build or 'EMPTY'}"
        )


def classify_platform(name: str) -> str:
    patterns = (
        (r"-ios-arm64\.ipa$", "ios-arm64"),
        (r"-ios\.spdx\.json$", "ios-sbom"),
        (r"-ios-native-deps\.zip$", "ios-native-dependency-evidence"),
        (r"-windows-x64\.zip$", "windows-x64"),
        (r"-android-arm64-v8a\.apk$", "android-arm64-v8a"),
        (r"-android-armeabi-v7a\.apk$", "android-armeabi-v7a"),
        (r"-android-x86_64\.apk$", "android-x86_64"),
        (r"-web-any\.tar\.gz$", "web-any"),
        (r"-server-(?:api|worker|migrate)-linux-amd64\.tar$", "linux-amd64"),
        (r"\.spdx\.json$", "sbom"),
        (r"\.trivy\.json$", "security-report"),
    )
    for pattern, platform in patterns:
        if re.search(pattern, name):
            return platform
    return "release-metadata"


def collect_subjects(root: Path, excluded: set[Path]) -> list[dict[str, object]]:
    subjects: list[dict[str, object]] = []
    for path in iter_release_files(root.resolve(), {item.resolve() for item in excluded}):
        relative = path.resolve().relative_to(root.resolve()).as_posix()
        subjects.append(
            {
                "name": relative,
                "platform": classify_platform(relative),
                "sizeBytes": path.stat().st_size,
                "sha256": sha256_file(path),
            }
        )
    return subjects


def release_metadata(
    root: Path,
    output: Path,
    version: str,
    tag: str,
    commit: str,
    commit_date: str,
    commit_count: int,
    previous_release: str,
) -> None:
    validate_semver(version)
    if tag != f"v{version}":
        raise ReleaseContractError("metadata tag/version mismatch")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ReleaseContractError("metadata commit must be a full 40-character SHA")
    excluded = {output.resolve()}
    subjects = collect_subjects(root, excluded)
    payload = {
        "schemaVersion": 1,
        "product": "DD",
        "releaseVersion": version,
        "gitTag": tag,
        "gitCommit": commit,
        "gitCommitDate": commit_date,
        "gitCommitCount": commit_count,
        "previousFormalRelease": None if previous_release in ("", "NONE") else previous_release,
        "artifactCount": len(subjects),
        "artifacts": subjects,
        "rollbackPolicy": {
            "application": "retain immutable previous release artifacts/images",
            "database": "forward-only migrations; restore verified pre-upgrade backup when previous app rejects newer schema",
            "automaticDownMigration": False,
        },
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def provenance_manifest(
    root: Path,
    output: Path,
    metadata_path: Path,
    repository: str,
    workflow_run_url: str,
) -> None:
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    subjects = [
        {"name": item["name"], "digest": {"sha256": item["sha256"]}}
        for item in metadata["artifacts"]
    ]
    payload = {
        "_type": "https://in-toto.io/Statement/v1",
        "subject": subjects,
        "predicateType": "https://dd.example/schema/release-provenance/v1",
        "predicate": {
            "releaseVersion": metadata["releaseVersion"],
            "gitTag": metadata["gitTag"],
            "gitCommit": metadata["gitCommit"],
            "gitCommitDate": metadata["gitCommitDate"],
            "repository": repository,
            "workflowRun": workflow_run_url,
            "buildPlatforms": sorted(
                {item["platform"] for item in metadata["artifacts"]}
            ),
            "note": (
                "This downloadable manifest is descriptive. GitHub Artifact "
                "Attestations generated by actions/attest-build-provenance are "
                "the cryptographically signed provenance."
            ),
        },
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def command_validate(args: argparse.Namespace) -> None:
    repo = Path(args.repo).resolve()
    tag = args.tag
    version = version_from_tag(tag)
    ensure_clean(repo)
    ensure_exact_tag(repo, tag)
    ensure_changelog(Path(args.changelog).resolve(), version)
    facts = git_facts(repo)
    outputs = {
        "version": version,
        "ios_version": ios_marketing_version(version),
        "tag": tag,
        "sha": facts["gitCommit"],
        "commit_count": facts["gitCommitCount"],
        "commit_date": facts["gitCommitDate"],
        "source_date_epoch": facts["sourceDateEpoch"],
    }
    if args.github_output:
        write_github_outputs(Path(args.github_output), outputs)
    print(json.dumps(outputs, sort_keys=True))


def command_previous_release(args: argparse.Namespace) -> None:
    payload = json.loads(Path(args.releases_json).read_text(encoding="utf-8"))
    previous = resolve_previous_formal_release(payload, args.current_tag)
    ensure_previous_release_assets(previous)
    outputs = {
        "previous_release": previous["tag"],
        "previous_asset_count": previous["assetCount"],
        "previous_published_at": previous["publishedAt"] or "NONE",
    }
    if args.github_output:
        write_github_outputs(Path(args.github_output), outputs)
    print(json.dumps(previous, sort_keys=True))


def command_verify_ios_ipa(args: argparse.Namespace) -> None:
    validate_ios_ipa_shape(Path(args.ipa), args.version, args.build_number)
    print(args.ipa)


def command_checksums(args: argparse.Namespace) -> None:
    count = write_checksums(Path(args.root), Path(args.output))
    print(f"checksummed {count} release files")


def command_verify_checksums(args: argparse.Namespace) -> None:
    count = verify_checksums(Path(args.root), Path(args.manifest))
    print(f"verified {count} release checksums")


def command_metadata(args: argparse.Namespace) -> None:
    release_metadata(
        root=Path(args.root),
        output=Path(args.output),
        version=args.version,
        tag=args.tag,
        commit=args.commit,
        commit_date=args.commit_date,
        commit_count=args.commit_count,
        previous_release=args.previous_release,
    )
    print(args.output)


def command_provenance(args: argparse.Namespace) -> None:
    provenance_manifest(
        root=Path(args.root),
        output=Path(args.output),
        metadata_path=Path(args.metadata),
        repository=args.repository,
        workflow_run_url=args.workflow_run_url,
    )
    print(args.output)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    validate = sub.add_parser("validate")
    validate.add_argument("--repo", default=".")
    validate.add_argument("--tag", required=True)
    validate.add_argument("--changelog", default="CHANGELOG.md")
    validate.add_argument("--github-output", default="")
    validate.set_defaults(func=command_validate)

    previous = sub.add_parser("previous-release")
    previous.add_argument("--releases-json", required=True)
    previous.add_argument("--current-tag", required=True)
    previous.add_argument("--github-output", default="")
    previous.set_defaults(func=command_previous_release)

    ios = sub.add_parser("verify-ios-ipa")
    ios.add_argument("--ipa", required=True)
    ios.add_argument("--version", required=True)
    ios.add_argument("--build-number", type=int, required=True)
    ios.set_defaults(func=command_verify_ios_ipa)

    checksums = sub.add_parser("checksums")
    checksums.add_argument("--root", required=True)
    checksums.add_argument("--output", required=True)
    checksums.set_defaults(func=command_checksums)

    verify = sub.add_parser("verify-checksums")
    verify.add_argument("--root", required=True)
    verify.add_argument("--manifest", required=True)
    verify.set_defaults(func=command_verify_checksums)

    metadata = sub.add_parser("metadata")
    metadata.add_argument("--root", required=True)
    metadata.add_argument("--output", required=True)
    metadata.add_argument("--version", required=True)
    metadata.add_argument("--tag", required=True)
    metadata.add_argument("--commit", required=True)
    metadata.add_argument("--commit-date", required=True)
    metadata.add_argument("--commit-count", type=int, required=True)
    metadata.add_argument("--previous-release", default="NONE")
    metadata.set_defaults(func=command_metadata)

    provenance = sub.add_parser("provenance")
    provenance.add_argument("--root", required=True)
    provenance.add_argument("--output", required=True)
    provenance.add_argument("--metadata", required=True)
    provenance.add_argument("--repository", required=True)
    provenance.add_argument("--workflow-run-url", required=True)
    provenance.set_defaults(func=command_provenance)

    return parser


def main() -> int:
    try:
        args = build_parser().parse_args()
        args.func(args)
        return 0
    except ReleaseContractError as exc:
        print(f"[release-contract] ERROR: {exc}", file=sys.stderr)
        return 2
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"[release-contract] ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
