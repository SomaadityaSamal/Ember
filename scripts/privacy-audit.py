#!/usr/bin/env python3
"""Bounded source/bundle hygiene checks. Never prints matched secret contents."""
import argparse
import pathlib
import plistlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE_ROOTS = ["Sources", "Resources", "Tests", "scripts", "docs", ".github"]
SOURCE_FILES = ["Package.swift", "README.md", "SECURITY.md", "LICENSE", ".gitignore"]
SECRET_SUFFIXES = {".pem", ".p12", ".pfx", ".key", ".keychain", ".keychain-db", ".mobileprovision", ".provisionprofile"}
PATTERNS = [
    ("private key", re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    ("GitHub token", re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})")),
    ("OpenAI credential", re.compile(rb"sk-(?:proj-|svcacct-)[A-Za-z0-9_-]{30,}")),
    ("AWS access credential", re.compile(rb"(?:AKIA|ASIA)[A-Z0-9]{16}")),
    ("Slack credential", re.compile(rb"xox[baprs]-[A-Za-z0-9-]{20,}")),
    ("local home path", re.compile(rb"/(?:Users|home)/[A-Za-z0-9_.-]+/")),
]
issues = []

def inspect(path, bundle=False):
    if path.is_symlink():
        issues.append((path, "symlinks are not allowed")); return
    if path.suffix.lower() in SECRET_SUFFIXES or path.name == ".env" or path.name.startswith(".env."):
        issues.append((path, "forbidden secret filename")); return
    data = path.read_bytes()
    for label, pattern in PATTERNS:
        if pattern.search(data): issues.append((path, label))
    # The app should never collect/transmit diagnostics or log process names by default.
    if "Sources" in path.parts and path.suffix in {".swift", ".c", ".h"}:
        for api in [b"URLSession", b"NSURLSession", b"NSLog(", b"os_log("]:
            if api in data: issues.append((path, "unexpected networking/logging API"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=pathlib.Path)
    args = parser.parse_args()
    sources = [ROOT / name for name in SOURCE_FILES if (ROOT / name).is_file()]
    for name in SOURCE_ROOTS:
        sources.extend(p for p in (ROOT / name).rglob("*") if p.is_file() and "__pycache__" not in p.parts)
    for path in sources: inspect(path)
    print(f"Inspected {len(sources)} public source/documentation files.")
    if args.app:
        app = args.app.resolve()
        allowed = {
            "Contents/Info.plist", "Contents/Resources/Ember.icns", "Contents/_CodeSignature/CodeResources",
            "Contents/MacOS/Ember", "Contents/MacOS/EmberFanClient", "Contents/MacOS/EmberFanHelper",
            "Contents/Library/LaunchDaemons/app.ember.heatmonitor.fans.plist",
        }
        present = set()
        for path in app.rglob("*"):
            if path.is_file() or path.is_symlink():
                relative = path.relative_to(app).as_posix(); present.add(relative)
                if relative not in allowed: issues.append((path, "unexpected release-bundle file"))
                inspect(path, bundle=True)
        for missing in allowed - present: issues.append((app / missing, "missing release-bundle file"))
        result = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True)
        if result.returncode: issues.append((app, "sealed signature validation failed"))
        client = app / "Contents/MacOS/EmberFanClient"
        code = subprocess.run(["codesign", "-dvvv", str(client)], capture_output=True).stderr
        match = re.search(rb"^CDHash=([a-f0-9]{40})$", code, re.M)
        expected = b'identifier "app.ember.heatmonitor.fanclient" and cdhash H"' + (match[1] if match else b"invalid") + b'"\0'
        helper = app / "Contents/MacOS/EmberFanHelper"
        if not match or expected not in helper.read_bytes(): issues.append((helper, "client signature pin does not match packaged client"))
        helper_identity = subprocess.run(["codesign", "-dvvv", str(helper)], capture_output=True).stderr
        helper_hash = re.search(rb"^CDHash=([a-f0-9]{40})$", helper_identity, re.M)
        launch_plist = app / "Contents/Library/LaunchDaemons/app.ember.heatmonitor.fans.plist"
        launch = plistlib.loads(launch_plist.read_bytes())
        constraint = launch.get("SpawnConstraint", {})
        if (not helper_hash or constraint.get("signing-identifier") != "app.ember.heatmonitor.fans" or
                constraint.get("cdhash") != bytes.fromhex(helper_hash[1].decode())):
            issues.append((launch_plist, "helper launch pin does not match packaged helper"))
        print(f"Inspected {len(present)} packaged files and validated signing/pinning.")
    if issues:
        for path, label in issues:
            print(f"FAIL: {path.relative_to(ROOT) if path.is_relative_to(ROOT) else path.name}: {label}", file=sys.stderr)
        return 1
    print("PASS: no credential patterns, local home paths, forbidden files, or unexpected runtime networking/logging found.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
