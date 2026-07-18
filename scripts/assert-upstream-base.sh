#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

frozen="$(
  python3 - <<'PY'
import json
from pathlib import Path

lock = json.loads(Path("build/inputs.lock.json").read_text())
source = lock["source"]
print("\t".join((source["tagObject"], source["commit"], source["tree"])))
PY
)"

IFS=$'\t' read -r tag_object upstream_commit upstream_tree <<<"$frozen"

if [[ "$(git cat-file -t "$tag_object")" != "tag" ]]; then
  echo "expected frozen upstream tag object $tag_object" >&2
  exit 1
fi

if [[ "$(git rev-parse "${tag_object}^{commit}")" != "$upstream_commit" ]]; then
  echo "frozen upstream tag does not resolve to $upstream_commit" >&2
  exit 1
fi

if [[ "$(git cat-file -t "$upstream_commit")" != "commit" ]]; then
  echo "expected frozen upstream commit $upstream_commit" >&2
  exit 1
fi

if [[ "$(git rev-parse "${upstream_commit}^{tree}")" != "$upstream_tree" ]]; then
  echo "frozen upstream commit tree does not match $upstream_tree" >&2
  exit 1
fi

if ! git merge-base --is-ancestor "$upstream_commit" HEAD; then
  echo "HEAD is not descended from the frozen upstream commit" >&2
  exit 1
fi

if [[ "$(git merge-base "$upstream_commit" HEAD)" != "$upstream_commit" ]]; then
  echo "HEAD has an unexpected merge base" >&2
  exit 1
fi

echo "PASS: HEAD is rooted at frozen upstream Codex $upstream_commit"
