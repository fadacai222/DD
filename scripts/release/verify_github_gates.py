#!/usr/bin/env python3
"""Verify that required upstream GitHub Actions gates passed for one exact SHA."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


class GateError(RuntimeError):
    pass


def api_json(url: str, token: str) -> dict:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "dd-release-gate/1",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise GateError(f"GitHub API returned HTTP {exc.code}: {body[:500]}") from exc
    except urllib.error.URLError as exc:
        raise GateError(f"GitHub API request failed: {exc}") from exc


def verify_branch_head(*, repository: str, branch: str, sha: str, token: str) -> dict:
    quoted_branch = urllib.parse.quote(branch, safe="")
    url = f"https://api.github.com/repos/{repository}/git/ref/heads/{quoted_branch}"
    payload = api_json(url, token)
    ref = payload.get("ref")
    object_data = payload.get("object")
    branch_sha = object_data.get("sha") if isinstance(object_data, dict) else None
    if ref != f"refs/heads/{branch}" or branch_sha != sha:
        raise GateError(
            f"formal release SHA {sha} is not the current {branch} head; "
            f"GitHub reports {branch_sha!r}"
        )
    return {"ref": ref, "sha": branch_sha}


def verify_workflow(
    *, repository: str, workflow: str, sha: str, branch: str, token: str
) -> dict:
    quoted_workflow = urllib.parse.quote(workflow, safe="")
    query = urllib.parse.urlencode(
        {
            "head_sha": sha,
            "status": "completed",
            "per_page": "100",
        }
    )
    url = (
        f"https://api.github.com/repos/{repository}/actions/workflows/"
        f"{quoted_workflow}/runs?{query}"
    )
    payload = api_json(url, token)
    runs = payload.get("workflow_runs")
    if not isinstance(runs, list):
        raise GateError(f"unexpected workflow-runs response for {workflow}")

    candidates = [
        run
        for run in runs
        if run.get("head_sha") == sha
        and run.get("head_branch") == branch
        and run.get("event") == "push"
    ]
    successful = [run for run in candidates if run.get("conclusion") == "success"]
    if not successful:
        conclusions = sorted(
            {str(run.get("conclusion")) for run in candidates if run.get("conclusion")}
        )
        detail = ", ".join(conclusions) if conclusions else "no completed push run found"
        raise GateError(
            f"required workflow {workflow} has no successful push run on "
            f"{branch} for exact SHA {sha}: {detail}"
        )

    selected = max(
        successful,
        key=lambda run: (int(run.get("run_number") or 0), int(run.get("run_attempt") or 0)),
    )
    return {
        "workflow": workflow,
        "runId": selected.get("id"),
        "runNumber": selected.get("run_number"),
        "runAttempt": selected.get("run_attempt"),
        "htmlUrl": selected.get("html_url"),
        "conclusion": selected.get("conclusion"),
        "headSha": selected.get("head_sha"),
        "headBranch": selected.get("head_branch"),
        "event": selected.get("event"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--branch", default="master")
    parser.add_argument("--workflow", action="append", required=True)
    parser.add_argument("--output", default="")
    args = parser.parse_args()

    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if not token:
        print("[release-gates] ERROR: GITHUB_TOKEN is required", file=sys.stderr)
        return 2
    if not args.repository or "/" not in args.repository:
        print("[release-gates] ERROR: repository must be owner/name", file=sys.stderr)
        return 2
    if len(args.sha) != 40 or any(ch not in "0123456789abcdef" for ch in args.sha):
        print("[release-gates] ERROR: --sha must be a full lowercase commit SHA", file=sys.stderr)
        return 2

    try:
        branch_head = verify_branch_head(
            repository=args.repository,
            branch=args.branch,
            sha=args.sha,
            token=token,
        )
        evidence = [
            verify_workflow(
                repository=args.repository,
                workflow=workflow,
                sha=args.sha,
                branch=args.branch,
                token=token,
            )
            for workflow in args.workflow
        ]
    except GateError as exc:
        print(f"[release-gates] ERROR: {exc}", file=sys.stderr)
        return 2

    payload = {
        "repository": args.repository,
        "gitCommit": args.sha,
        "branch": args.branch,
        "branchHead": branch_head,
        "requiredWorkflows": evidence,
    }
    rendered = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    if args.output:
        with open(args.output, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(rendered)
    print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
