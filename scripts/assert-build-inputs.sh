#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

python3 - <<'PY'
import hashlib
import json
from pathlib import Path
from urllib.parse import urlsplit

lock = json.loads(Path("build/inputs.lock.json").read_text())
documents = {
    name: Path(name).read_text()
    for name in (
        "build/Dockerfile.builder",
        "build/fetch-inputs.sh",
        "build/build-rusty-v8.sh",
    )
}


def require(path: str, *values: object) -> None:
    missing = [str(value) for value in values if str(value) not in documents[path]]
    if missing:
        raise SystemExit(f"{path} is missing frozen values: {missing}")


def verify_locked_file(entry: dict[str, object]) -> None:
    path = Path(str(entry["path"]))
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != entry["sha256"]:
        raise SystemExit(f"{path} hash mismatch: {actual} != {entry['sha256']}")


builder = lock["builder"]
docker = "build/Dockerfile.builder"
require(
    docker,
    f'{builder["baseImage"]}@{builder["linuxAmd64ManifestDigest"]}',
    builder["ubuntuSnapshot"],
)

rust = lock["rust"]
for artifact in rust["artifacts"]:
    url = urlsplit(artifact["url"])
    require(
        docker,
        f"{url.scheme}://{url.netloc}{str(Path(url.path).parent)}/",
        Path(url.path).name,
        artifact["size"],
        artifact["sha256"],
    )

android = lock["android"]
ndk = android["ndk"]
verify_locked_file(android["targetEnvironment"])
target_env = dict(
    line.split("=", 1)
    for line in Path(android["targetEnvironment"]["path"]).read_text().splitlines()
    if line and not line.startswith("#")
)
expected_env = {
    "ANDROID_TARGET_TRIPLE": android["targetTriple"],
    "ANDROID_ABI": android["abi"],
    "ANDROID_API_LEVEL": android["apiLevel"],
    "ANDROID_NDK_REVISION": ndk["revision"],
    "ANDROID_NDK_VERSION": ndk["version"],
    "RUST_VERSION": rust["version"],
    "SOURCE_DATE_EPOCH": lock["source"]["sourceDateEpoch"],
}
for name, expected in expected_env.items():
    if target_env.get(name) != str(expected):
        raise SystemExit(f"target environment mismatch for {name}")

fetch = "build/fetch-inputs.sh"
require(
    fetch,
    ndk["linuxArchiveUrl"],
    ndk["linuxArchiveSize"],
    ndk["linuxArchiveSha1"],
    ndk["linuxArchiveSha256"],
)

v8 = lock["rustyV8"]
verify_locked_file(
    {"path": v8["submoduleLockPath"], "sha256": v8["submoduleLockSha256"]}
)
require(
    fetch,
    v8["repository"],
    v8["tag"],
    v8["commit"],
    v8["cargoLockSha256"],
    v8["cargoTomlSha256"],
    v8["submoduleLockSha256"],
)

build_inputs = lock["rustyV8BuildInputs"]
for checkout in ("androidPlatform", "catapult"):
    require(
        fetch,
        build_inputs[checkout]["repository"],
        build_inputs[checkout]["commit"],
    )
for tool in ("gn", "ninja"):
    entry = build_inputs[tool]
    require(
        fetch,
        entry["cipdPackage"],
        entry["cipdInstance"],
        entry["archiveSize"],
        entry["archiveSha256"],
        entry["binarySha256"],
    )
for archive in ("chromiumRustToolchain", "hostSysroot"):
    entry = build_inputs[archive]
    url = urlsplit(entry["url"])
    require(
        fetch,
        f"{url.scheme}://{url.netloc}/",
        *url.path.strip("/").split("/"),
        entry["size"],
        entry["sha256"],
    )

build = "build/build-rusty-v8.sh"
require(
    build,
    v8["commit"],
    v8["sourceDateEpoch"],
    v8["cargoLockSha256"],
    v8["cargoTomlSha256"],
    v8["submoduleLockSha256"],
    android["targetEnvironment"]["sha256"],
    build_inputs["androidPlatform"]["commit"],
    build_inputs["catapult"]["commit"],
    ndk["linuxArchiveSize"],
    ndk["linuxArchiveSha256"],
)
for tool in ("gn", "ninja"):
    entry = build_inputs[tool]
    require(build, entry["archiveSize"], entry["archiveSha256"], entry["binarySha256"])
for archive in ("chromiumRustToolchain", "hostSysroot"):
    entry = build_inputs[archive]
    require(build, entry["size"], entry["sha256"])

print("PASS: build scripts match the frozen Android input manifest")
PY
