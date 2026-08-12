#!/usr/bin/env python3
"""Trigger the Codemagic signed iOS workflow and retrieve its exact IPA.

Apple signing material never enters GitHub Actions.  GitHub holds only a
Codemagic API token and app id; Codemagic injects the Apple integration and
release identity from its protected variable group.
"""
from __future__ import annotations

import argparse
import json
import os
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

API_START = "https://api.codemagic.io/builds"
API_V3 = "https://codemagic.io/api/v3/builds/{build_id}"
TERMINAL = {"finished", "failed", "canceled", "timeout", "skipped"}


class BridgeError(RuntimeError):
    pass


def request_json(url: str, token: str, *, method: str = "GET", payload: object | None = None) -> Any:
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("x-auth-token", token)
    req.add_header("Accept", "application/json")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:1000]
        raise BridgeError(f"Codemagic API HTTP {exc.code}: {detail}") from exc
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise BridgeError(f"Codemagic API request failed: {exc}") from exc


def find_artifact_url(value: object, expected_name: str) -> str | None:
    if isinstance(value, dict):
        name = value.get("name") or value.get("filename") or value.get("fileName")
        url = value.get("url") or value.get("downloadUrl") or value.get("secureUrl")
        if isinstance(name, str) and name == expected_name and isinstance(url, str) and url.startswith("https://"):
            return url
        for child in value.values():
            found = find_artifact_url(child, expected_name)
            if found:
                return found
    elif isinstance(value, list):
        for child in value:
            found = find_artifact_url(child, expected_name)
            if found:
                return found
    elif isinstance(value, str) and value.startswith("https://") and value.rstrip("/").endswith("/" + expected_name):
        return value
    return None


def download(url: str, token: str, output: Path, *, min_bytes: int = 1) -> None:
    req = urllib.request.Request(url, method="GET")
    req.add_header("x-auth-token", token)
    try:
        with urllib.request.urlopen(req, timeout=120) as response:
            data = response.read()
    except urllib.error.HTTPError as exc:
        raise BridgeError(f"artifact download failed with HTTP {exc.code}") from exc
    if len(data) < min_bytes:
        raise BridgeError(f"downloaded artifact is unexpectedly small: {len(data)} bytes")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(data)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-id", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--ios-version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--workflow", default="ios-signed-release")
    parser.add_argument("--poll-seconds", type=int, default=30)
    parser.add_argument("--max-polls", type=int, default=180)
    args = parser.parse_args()

    token = os.environ.get("DD_CODEMAGIC_API_TOKEN", "").strip()
    if not token:
        raise BridgeError("DD_CODEMAGIC_API_TOKEN is required")
    if args.tag != f"v{args.version}":
        raise BridgeError("tag/version mismatch")
    if args.ios_version != args.version.split("-", 1)[0]:
        raise BridgeError("iOS marketing version must equal the SemVer core version")
    if not args.build_number.isdigit() or int(args.build_number) <= 0:
        raise BridgeError("build number must be a positive integer")

    payload = {
        "appId": args.app_id,
        "workflowId": args.workflow,
        "tag": args.tag,
        "environment": {
            "variables": {
                "DD_RELEASE_TAG": args.tag,
                "DD_RELEASE_VERSION": args.version,
                "DD_RELEASE_SHA": args.sha,
                "DD_IOS_MARKETING_VERSION": args.ios_version,
                "DD_RELEASE_BUILD_NUMBER": args.build_number,
            }
        },
    }
    started = request_json(API_START, token, method="POST", payload=payload)
    build_id = started.get("buildId") if isinstance(started, dict) else None
    if not isinstance(build_id, str) or not build_id:
        raise BridgeError("Codemagic start-build response has no buildId")
    print(f"Codemagic signed iOS build: {build_id}")

    build: object = {}
    status = ""
    for _ in range(args.max_polls):
        build = request_json(API_V3.format(build_id=build_id), token)
        data = build.get("data") if isinstance(build, dict) else None
        status = data.get("status") if isinstance(data, dict) else None
        if not isinstance(status, str):
            raise BridgeError("Codemagic v3 response has no data.status")
        print(f"Codemagic status: {status}")
        if status in TERMINAL:
            break
        time.sleep(args.poll_seconds)
    else:
        raise BridgeError("Codemagic signed iOS build did not reach a terminal status")

    if status != "finished":
        raise BridgeError(f"Codemagic signed iOS build ended with status {status}")

    expected_name = f"DD-{args.tag}-ios-arm64.ipa"
    evidence_name = f"DD-{args.tag}-ios-native-deps.zip"
    artifact_url = find_artifact_url(build, expected_name)
    evidence_url = find_artifact_url(build, evidence_name)
    if not artifact_url or not evidence_url:
        # Artifact links can be populated shortly after the build reaches finished.
        # The legacy build-details endpoint remains the documented source for
        # authenticated artifact URLs, while v3 is authoritative for status.
        for _ in range(6):
            time.sleep(5)
            build = request_json(API_V3.format(build_id=build_id), token)
            details = request_json(f"{API_START}/{build_id}", token)
            artifact_url = artifact_url or find_artifact_url(build, expected_name) or find_artifact_url(details, expected_name)
            evidence_url = evidence_url or find_artifact_url(build, evidence_name) or find_artifact_url(details, evidence_name)
            if artifact_url and evidence_url:
                break
    if not artifact_url:
        raise BridgeError(f"finished Codemagic build exposes no exact artifact {expected_name}")
    if not evidence_url:
        raise BridgeError(f"finished Codemagic build exposes no exact artifact {evidence_name}")

    output = Path(args.output)
    if output.name != expected_name:
        raise BridgeError(f"output filename must be exactly {expected_name}")
    evidence_output = output.with_name(evidence_name)
    download(artifact_url, token, output, min_bytes=1024)
    download(evidence_url, token, evidence_output)
    print(output)
    print(evidence_output)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BridgeError as exc:
        print(f"[codemagic-ios] ERROR: {exc}", file=os.sys.stderr)
        raise SystemExit(2)
