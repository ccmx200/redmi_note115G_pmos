#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Delete old `build-<number>` releases from the ccmx200/redmi_note115G_pmos repo.

The same thing is available as the "cleanup old releases" GitHub Actions
workflow (Actions tab -> Run workflow); this script is for doing it from a
machine, e.g. after a local release run.

Only releases whose tag matches "build-<number>" are considered, so hand-made
releases are never deleted.  Assets and the git tag are removed with the release.

usage:
    GITHUB_TOKEN=ghp_xxx ./scripts/cleanup-releases.py [options]

options:
    --keep N       keep the N most recent build releases (default 5)
    --repo OWNER/NAME   default ccmx200/redmi_note115G_pmos
    --dry-run      only print what would be deleted
    --no-tags      leave the git tags in place
    --yes          do not ask for confirmation

The token needs the "repo" scope (classic) or "Contents: read and write"
(fine-grained).  It can also be supplied as the GH_TOKEN environment variable.
Behind a TLS-terminating proxy set GITHUB_INSECURE_TLS=1 to skip CA checks.
"""

import argparse
import json
import os
import re
import ssl
import subprocess
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"
BUILD_TAG = re.compile(r"^build-\d+$")


def ssl_context():
    # A local GitHub proxy that terminates TLS needs verification turned off
    # ("github 代理需要关闭 SSL 校验"); normal use keeps the default CA check.
    if os.environ.get("GITHUB_INSECURE_TLS", "").lower() in ("1", "true", "yes"):
        return ssl._create_unverified_context()
    return None


def token_from_env():
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        return token.strip()
    # fall back to the gh CLI credential store
    try:
        import subprocess

        return subprocess.run(
            ["gh", "auth", "token"], capture_output=True, text=True, check=True
        ).stdout.strip()
    except Exception:
        return ""


def api(token, method, path, body=None):
    # curl fallback: a local TLS-terminating proxy speaks HTTP/1.1 CONNECT in a way
    # urllib trips over (HTTP 500), while curl works fine; GITHUB_USE_CURL=1 selects it.
    if os.environ.get("GITHUB_USE_CURL", "").lower() in ("1", "true", "yes"):
        cmd = ["curl", "-sS", "-f", "-k", "-X", method,
               "-H", "Accept: application/vnd.github+json",
               "-H", "Authorization: token " + token,
               "-H", "User-Agent: evergo-cleanup"]
        data = None
        if body is not None:
            data = json.dumps(body)
            cmd += ["-H", "Content-Type: application/json", "--data-binary", data]
        cmd.append(API + path)
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode not in (0, 22):  # 22 = HTTP error already printed by -f
            raise RuntimeError(res.stderr.strip())
        if res.returncode == 22:
            raise urllib.error.HTTPError(API + path, 0, res.stderr.strip(), None, None)
        if res.stdout.strip():
            return json.loads(res.stdout)
        return None

    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("Authorization", "token " + token)
    req.add_header("User-Agent", "evergo-cleanup")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    ctx = ssl_context()
    with urllib.request.urlopen(req, timeout=60, context=ctx) as resp:
        if resp.status == 204:
            return None
        return json.loads(resp.read().decode() or "null")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--keep", type=int, default=5, help="how many recent builds to keep")
    ap.add_argument("--repo", default="ccmx200/redmi_note115G_pmos")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-tags", action="store_true")
    ap.add_argument("--yes", action="store_true")
    args = ap.parse_args()

    token = token_from_env()
    if not token:
        sys.exit("no token: set GITHUB_TOKEN/GH_TOKEN or log in with `gh auth login`")

    owner, _, repo = args.repo.partition("/")
    if not repo:
        sys.exit("--repo must be OWNER/NAME")

    releases = []
    page = 1
    while True:
        batch = api(token, "GET", f"/repos/{owner}/{repo}/releases?per_page=100&page={page}")
        if not batch:
            break
        releases.extend(batch)
        page += 1

    builds = [r for r in releases if BUILD_TAG.match(r["tag_name"])]
    builds.sort(key=lambda r: r["created_at"], reverse=True)

    print(f"{len(builds)} build releases found, keeping the newest {args.keep}")
    doomed = builds[args.keep:]
    if not doomed:
        print("nothing to delete")
        return

    for r in doomed:
        print(f"  delete {r['tag_name']:<16} {r['created_at']}  assets={len(r['assets'])}")
    if args.dry_run:
        print(f"dry run: would delete {len(doomed)} release(s)")
        return

    if not args.yes:
        try:
            answer = input(f"delete {len(doomed)} release(s)? [y/N] ").strip().lower()
        except EOFError:
            answer = ""
        if answer not in ("y", "yes"):
            sys.exit("aborted")

    for r in doomed:
        print(f"deleting {r['tag_name']} ...", end="", flush=True)
        try:
            api(token, "DELETE", f"/repos/{owner}/{repo}/releases/{r['id']}")
            if not args.no_tags:
                try:
                    api(token, "DELETE", f"/repos/{owner}/{repo}/git/refs/tags/{r['tag_name']}")
                except urllib.error.HTTPError as e:
                    if e.code != 404:
                        print(f" (tag not deleted: HTTP {e.code})", end="")
            print(" ok")
        except urllib.error.HTTPError as e:
            print(f" FAILED: HTTP {e.code} {e.reason}")


if __name__ == "__main__":
    main()
