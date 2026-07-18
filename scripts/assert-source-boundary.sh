#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

python3 - <<'PY'
import json
import hashlib
import subprocess
from pathlib import Path

manifest = json.loads(Path("android-patches.json").read_text())
inputs = json.loads(Path("build/inputs.lock.json").read_text())
if manifest.get("schemaVersion") != 1:
    raise SystemExit("unsupported android-patches.json schema")

downstream = manifest.get("downstream", {})
release_gate = inputs.get("releaseGate", {})
downstream_commit = downstream.get("commit")
if downstream.get("state") != "source_commit_frozen" or not downstream_commit:
    raise SystemExit("downstream Android source commit is not frozen")
if release_gate.get("blockedUntilFrozen") is not False:
    raise SystemExit("Android source release gate is still marked unfrozen")
if release_gate.get("downstreamCommit") != downstream_commit:
    raise SystemExit("downstream source commit differs across policy manifests")
actual_cargo_lock = hashlib.sha256(Path("codex-rs/Cargo.lock").read_bytes()).hexdigest()
if release_gate.get("downstreamCargoLockSha256") != actual_cargo_lock:
    raise SystemExit("downstream Cargo.lock differs from the frozen release gate")
subprocess.run(
    ["git", "merge-base", "--is-ancestor", downstream_commit, "HEAD"],
    check=True,
)

paths = []
for patch in manifest.get("patches", []):
    patch_paths = patch.get("paths", [])
    if not patch.get("id") or not patch_paths:
        raise SystemExit("every Android patch must have an id and at least one path")
    paths.extend(patch_paths)

if len(paths) != len(set(paths)):
    raise SystemExit("a source path is assigned to more than one Android patch")
if any(not path.startswith("codex-rs/") for path in paths):
    raise SystemExit("Android patch source paths must stay under codex-rs/")

allowed_source = set(paths)
allowed_policy = {
    ".gitignore",
    ".github/workflows/source-checks.yml",
    "android-patches.json",
    "build/android-target.env",
    "build/build-rusty-v8.sh",
    "build/Dockerfile.builder",
    "build/fetch-inputs.sh",
    "build/inputs.lock.json",
    "build/rusty-v8-submodules.lock",
    "scripts/assert-build-inputs.sh",
    "scripts/assert-managed-updates-disabled.sh",
    "scripts/assert-source-boundary.sh",
    "scripts/assert-upstream-base.sh",
}

upstream_commit = manifest["upstream"]["commit"]
changed = set(
    subprocess.check_output(
        ["git", "diff", "--no-renames", "--name-only", upstream_commit, "--"],
        text=True,
    ).splitlines()
)
changed.update(
    subprocess.check_output(
        ["git", "ls-files", "--others", "--exclude-standard"],
        text=True,
    ).splitlines()
)

unexpected = sorted(changed - allowed_source - allowed_policy)
if unexpected:
    formatted = "\n".join(f"  {path}" for path in unexpected)
    raise SystemExit(
        "unexpected paths outside the reviewed Android source boundary:\n" + formatted
    )

print("PASS: all downstream paths are inside the reviewed Android boundary")
PY
