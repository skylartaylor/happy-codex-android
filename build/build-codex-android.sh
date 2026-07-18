#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
umask 022

readonly SOURCE_COMMIT='ab9c3ec845b913c2a9adf23a60c4d04f65c647b1'
readonly CARGO_LOCK_SHA256='221542fd6c8d48fec346a6684cadc7bcbc110fa2a0f7f2e574b22523e0ef5f75'
readonly RUST_TOOLCHAIN_SHA256='570656042681cfd8795403a455baf9a33035331a07db0645e866bbcea89a3d64'
readonly TARGET_ENV_SHA256='1524456f7a6daab6e433248056dc136730a608d2e7f3079405927d636d0e15d3'
readonly TARGET='aarch64-linux-android'
readonly EXPECTED_ANDROID_API_LEVEL='29'
readonly NDK_VERSION='28.2.13676358'
readonly CODEX_VERSION='0.144.4'
readonly RUSTC_VERSION='rustc 1.95.0 (59807616e 2026-04-14)'
readonly CARGO_VERSION='cargo 1.95.0 (f2d3ce0bd 2026-03-21)'
readonly EXPECTED_SOURCE_DATE_EPOCH='1784002837'
readonly V8_ARCHIVE_NAME='librusty_v8_release_aarch64-linux-android.a'
readonly V8_ARCHIVE_GZIP_NAME="${V8_ARCHIVE_NAME}.gz"
readonly V8_BINDING_NAME='src_binding_release_aarch64-linux-android.rs'
readonly V8_ARCHIVE_EXPECTED_SHA256='aff3c75ff060e77319d93fc34483a0947b4bc2ad9d8597b9f9c44444857b91de'
readonly V8_ARCHIVE_GZIP_EXPECTED_SHA256='b396d07e5a390a264ac3a696d94b3ea465c9d19b4c60088b27c73aaf268457f0'
readonly V8_BINDING_EXPECTED_SHA256='cded03dd9deb0c84ec46f7d2f38da837e9ca551dacb8abb4ea8bd07fc312b7f9'
readonly V8_PREPARED_BINDING_SHA256='c03bb6bd234eda46b5591d9411825c8cedfe603f8e58c4bea49fe756b97396bb'
readonly CARGO_FETCH_MARKER='.codex-cargo-fetch-complete'
readonly PACKAGE_ROOT_NAME="happy-codex-android-aarch64-v${CODEX_VERSION}"
readonly ARCHIVE_NAME="${PACKAGE_ROOT_NAME}.tar.gz"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s INPUT_ROOT RUSTY_V8_ARTIFACT_ROOT OUTPUT_ROOT\n' "${0##*/}" >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

canonical_existing_directory() {
  [[ -d "$1" ]] || fail "directory does not exist: $1"
  (cd "$1" && pwd -P)
}

canonical_output_directory() {
  mkdir -p "$1"
  (cd "$1" && pwd -P)
}

file_size() {
  wc -c < "$1" | tr -d '[:space:]'
}

file_sha256() {
  sha256sum "$1" | awk '{print $1}'
}

verify_sha256() {
  local path="$1"
  local expected="$2"
  local label="$3"

  [[ -f "$path" && ! -L "$path" ]] || fail "$label is missing or is not a regular file"
  [[ "$(file_sha256 "$path")" == "$expected" ]] || fail "$label failed SHA-256 verification"
}

verify_elf() {
  local path="$1"
  local label="$2"
  local header program_headers dynamic

  header="$($READELF --file-header --wide "$path")"
  grep --fixed-strings 'Class:                             ELF64' <<<"$header" >/dev/null \
    || fail "$label is not ELF64"
  grep --fixed-strings "Data:                              2's complement, little endian" <<<"$header" >/dev/null \
    || fail "$label is not little-endian"
  grep --fixed-strings 'Type:                              DYN (Shared object file)' <<<"$header" >/dev/null \
    || fail "$label is not an ELF dynamic object"
  grep --fixed-strings 'Machine:                           AArch64' <<<"$header" >/dev/null \
    || fail "$label is not an AArch64 executable"

  program_headers="$($READELF --program-headers --wide "$path")"
  grep --fixed-strings '[Requesting program interpreter: /system/bin/linker64]' \
    <<<"$program_headers" >/dev/null || fail "$label has an unexpected program interpreter"

  dynamic="$($READELF --dynamic --wide "$path")"
  grep --extended-regexp '\(FLAGS_1\).*PIE' <<<"$dynamic" >/dev/null \
    || fail "$label is not marked as a position-independent executable"
  if grep --extended-regexp '\((RPATH|RUNPATH)\)' <<<"$dynamic" >/dev/null; then
    fail "$label contains a forbidden RPATH or RUNPATH"
  fi
}

verify_shared_library() {
  local path="$1"
  local label="$2"
  local header dynamic needed

  header="$($READELF --file-header --wide "$path")"
  grep --fixed-strings 'Class:                             ELF64' <<<"$header" >/dev/null \
    || fail "$label is not ELF64"
  grep --fixed-strings "Data:                              2's complement, little endian" <<<"$header" >/dev/null \
    || fail "$label is not little-endian"
  grep --fixed-strings 'Type:                              DYN (Shared object file)' <<<"$header" >/dev/null \
    || fail "$label is not a shared object"
  grep --fixed-strings 'Machine:                           AArch64' <<<"$header" >/dev/null \
    || fail "$label is not an AArch64 shared object"

  dynamic="$($READELF --dynamic --wide "$path")"
  if grep --extended-regexp '\((RPATH|RUNPATH)\)' <<<"$dynamic" >/dev/null; then
    fail "$label contains a forbidden RPATH or RUNPATH"
  fi
  while IFS= read -r needed; do
    case "$needed" in
      libc.so|libdl.so|libm.so)
        ;;
      *)
        fail "$label has an unexpected DT_NEEDED entry: $needed"
        ;;
    esac
  done < <(sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' <<<"$dynamic" | sort -u)
}

[[ $# -eq 3 ]] || usage
[[ "$(uname -s)" == 'Linux' && "$(uname -m)" == 'x86_64' ]] \
  || fail 'Codex Android must be built on Linux x86_64'

for command_name in awk cargo cat cmp diff git grep gzip head install mkdir mv nproc python3 rm rustc sed sha256sum sort tar tr wc; do
  require_command "$command_name"
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
readonly REPOSITORY_ROOT
[[ "$SCRIPT_DIR" == "$REPOSITORY_ROOT/build" ]] || fail 'build script is outside the source repository'
[[ "$(git -c safe.directory="$REPOSITORY_ROOT" -C "$REPOSITORY_ROOT" rev-parse --is-inside-work-tree)" == true \
  && "$(git -c safe.directory="$REPOSITORY_ROOT" -C "$REPOSITORY_ROOT" rev-parse --show-toplevel)" == "$REPOSITORY_ROOT" ]] \
  || fail 'build script is not inside the Codex source worktree'

git_repository() {
  git -c safe.directory="$REPOSITORY_ROOT" -C "$REPOSITORY_ROOT" "$@"
}

INPUT_ROOT="$(canonical_existing_directory "$1")"
readonly INPUT_ROOT
V8_ROOT="$(canonical_existing_directory "$2")"
readonly V8_ROOT
OUTPUT_ROOT="$(canonical_output_directory "$3")"
readonly OUTPUT_ROOT
[[ "$OUTPUT_ROOT" != "$INPUT_ROOT" && "$OUTPUT_ROOT" != "$V8_ROOT" \
  && "$OUTPUT_ROOT" != "$REPOSITORY_ROOT" ]] || fail 'output root overlaps a protected input'

readonly INPUT_LOCK_PATH="$REPOSITORY_ROOT/build/inputs.lock.json"
readonly TARGET_ENV_PATH="$REPOSITORY_ROOT/build/android-target.env"
readonly CARGO_HOME_PATH="$INPUT_ROOT/cargo-home"
readonly CARGO_MARKER_PATH="$CARGO_HOME_PATH/$CARGO_FETCH_MARKER"
readonly NDK_HOME="$INPUT_ROOT/android-ndk-r28c"
readonly NDK_BIN="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
readonly BUILTINS_ARCHIVE="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/19/lib/linux/libclang_rt.builtins-aarch64-android.a"
readonly READELF="$NDK_BIN/llvm-readelf"
readonly STRIP="$NDK_BIN/llvm-strip"
readonly AR="$NDK_BIN/llvm-ar"
readonly TARGET_DIR="$OUTPUT_ROOT/cargo-target"
readonly PACKAGE_DIR="$OUTPUT_ROOT/$PACKAGE_ROOT_NAME"
readonly ARCHIVE_PATH="$OUTPUT_ROOT/$ARCHIVE_NAME"
readonly ARCHIVE_CHECKSUM_PATH="${ARCHIVE_PATH}.sha256"
readonly SCRATCH_DIR="$OUTPUT_ROOT/.codex-android-build"
readonly BUILD_HOME="$OUTPUT_ROOT/build-home"
readonly BUILD_TMP="$OUTPUT_ROOT/tmp"

for path in "$TARGET_DIR" "$PACKAGE_DIR" "$ARCHIVE_PATH" "$ARCHIVE_CHECKSUM_PATH" \
  "$SCRATCH_DIR" "$BUILD_HOME" "$BUILD_TMP"; do
  [[ ! -e "$path" && ! -L "$path" ]] || fail "stale build output exists: $path"
done
mkdir -p "$SCRATCH_DIR" "$BUILD_HOME" "$BUILD_TMP"
cleanup() {
  rm -rf "$SCRATCH_DIR"
}
trap cleanup EXIT

python3 - "$INPUT_LOCK_PATH" <<'PY'
import json
import sys
from pathlib import Path

lock = json.loads(Path(sys.argv[1]).read_text())
expected = {
    "schemaVersion": 1,
    "state": "initial_android_candidate_inputs_frozen",
    "sourceCommit": "ab9c3ec845b913c2a9adf23a60c4d04f65c647b1",
    "cargoLockSha256": "221542fd6c8d48fec346a6684cadc7bcbc110fa2a0f7f2e574b22523e0ef5f75",
    "target": "aarch64-linux-android",
    "apiLevel": 29,
    "version": "0.144.4",
    "package": "codex-cli",
    "binary": "codex",
    "marker": ".codex-cargo-fetch-complete",
    "cargoFetch": {
        "markerSchemaVersion": 2,
        "scope": "all_locked_targets",
        "offlineVerificationPackage": "codex-cli",
        "offlineVerificationTargets": ["all", "aarch64-linux-android"],
        "regressionCrate": {
            "name": "arboard",
            "version": "3.6.1",
            "sha256": "0348a1c054491f4bfe6ab86a7b6ab1e44e45d899005de92f58b3df180b36ddaf",
        },
    },
    "rustyV8BindingPatch": {
        "state": "required_android_bindgen_aliases",
        "sourceSha256": "cded03dd9deb0c84ec46f7d2f38da837e9ca551dacb8abb4ea8bd07fc312b7f9",
        "preparedSha256": "c03bb6bd234eda46b5591d9411825c8cedfe603f8e58c4bea49fe756b97396bb",
        "aliases": [
            "v8_String_WriteFlags_kNullTerminate",
            "v8_String_WriteFlags_kReplaceInvalidUtf8",
        ],
    },
    "v8Commit": "5d0e31ea6bf67f4559faa759b91e22bc3f1cd696",
    "v8Version": "149.2.0",
    "artifactId": "happy-codex-android-aarch64-v0.144.4",
    "archiveRoot": "happy-codex-android-aarch64-v0.144.4",
    "archiveFilename": "happy-codex-android-aarch64-v0.144.4.tar.gz",
    "promotionStatus": "unapproved_poc",
}
actual = {
    "schemaVersion": lock.get("schemaVersion"),
    "state": lock.get("state"),
    "sourceCommit": lock.get("releaseGate", {}).get("downstreamCommit"),
    "cargoLockSha256": lock.get("releaseGate", {}).get("downstreamCargoLockSha256"),
    "target": lock.get("android", {}).get("targetTriple"),
    "apiLevel": lock.get("android", {}).get("apiLevel"),
    "version": lock.get("codexBuild", {}).get("version"),
    "package": lock.get("codexBuild", {}).get("cargoPackage"),
    "binary": lock.get("codexBuild", {}).get("binary"),
    "marker": lock.get("codexBuild", {}).get("cargoHomeCompletionMarker"),
    "cargoFetch": lock.get("codexBuild", {}).get("cargoFetch"),
    "rustyV8BindingPatch": lock.get("codexBuild", {}).get("rustyV8BindingPatch"),
    "v8Commit": lock.get("rustyV8", {}).get("commit"),
    "v8Version": lock.get("rustyV8", {}).get("crateVersion"),
    "artifactId": lock.get("codexBuild", {}).get("package", {}).get("artifactId"),
    "archiveRoot": lock.get("codexBuild", {}).get("package", {}).get("archiveRoot"),
    "archiveFilename": lock.get("codexBuild", {}).get("package", {}).get("archiveFilename"),
    "promotionStatus": lock.get("codexBuild", {}).get("package", {}).get("promotionStatus"),
}
if actual != expected:
    raise SystemExit(f"frozen Codex build contract mismatch: {actual!r}")

elf = lock.get("codexBuild", {}).get("elf", {})
if elf != {
    "class": "ELF64",
    "machine": "AArch64",
    "interpreter": "/system/bin/linker64",
    "neededAllowlist": ["libc.so", "libc++_shared.so", "libdl.so", "liblog.so", "libm.so"],
}:
    raise SystemExit("frozen Codex ELF contract mismatch")
PY

verify_sha256 "$TARGET_ENV_PATH" "$TARGET_ENV_SHA256" 'Android target environment'
set -a
# shellcheck source=/dev/null
source "$TARGET_ENV_PATH"
set +a
[[ "${ANDROID_TARGET_TRIPLE:-}" == "$TARGET" \
  && "${ANDROID_API_LEVEL:-}" == "$EXPECTED_ANDROID_API_LEVEL" \
  && "${ANDROID_NDK_VERSION:-}" == "$NDK_VERSION" \
  && "${RUST_VERSION:-}" == '1.95.0' \
  && "${SOURCE_DATE_EPOCH:-}" == "$EXPECTED_SOURCE_DATE_EPOCH" ]] \
  || fail 'Android target environment does not match the frozen build contract'

[[ -f "$INPUT_ROOT/.complete" && ! -L "$INPUT_ROOT/.complete" ]] \
  || fail 'input root was not finalized by fetch-inputs.sh'
(cd "$INPUT_ROOT" && sha256sum --check --strict inputs.lock.sha256 >/dev/null) \
  || fail 'input lock checksum is invalid'
[[ -d "$CARGO_HOME_PATH" && ! -L "$CARGO_HOME_PATH" ]] \
  || fail 'input root does not contain the frozen Cargo home'
[[ ! -e "$CARGO_HOME_PATH/config" && ! -e "$CARGO_HOME_PATH/config.toml" \
  && ! -e "$CARGO_HOME_PATH/credentials" && ! -e "$CARGO_HOME_PATH/credentials.toml" ]] \
  || fail 'frozen Cargo home contains a configuration or credentials override'
[[ -f "$CARGO_MARKER_PATH" && ! -L "$CARGO_MARKER_PATH" ]] \
  || fail 'Codex Cargo fetch completion marker is missing'
cat > "$SCRATCH_DIR/expected-cargo-marker" <<EOF
schema_version=2
source_commit=${SOURCE_COMMIT}
cargo_lock_sha256=${CARGO_LOCK_SHA256}
target=${TARGET}
cargo_version=1.95.0
fetch_scope=all_locked_targets
verified_package=codex-cli
verified_targets=all,${TARGET}
regression_crate=arboard@3.6.1
EOF
cmp --silent "$SCRATCH_DIR/expected-cargo-marker" "$CARGO_MARKER_PATH" \
  || fail 'Codex Cargo fetch completion marker does not match the frozen source'

[[ -x "$READELF" && -x "$STRIP" && -x "$AR" \
  && -x "$NDK_BIN/aarch64-linux-android29-clang" \
  && -x "$NDK_BIN/aarch64-linux-android29-clang++" \
  && -x "$NDK_BIN/llvm-ranlib" \
  && -f "$BUILTINS_ARCHIVE" ]] || fail 'pinned NDK tools or compiler-rt builtins are incomplete'
grep --fixed-strings --line-regexp "Pkg.Revision = $NDK_VERSION" "$NDK_HOME/source.properties" >/dev/null \
  || fail 'extracted NDK has an unexpected revision'
[[ "$(rustc --version)" == "$RUSTC_VERSION" ]] || fail 'rustc version does not match the frozen builder'
[[ "$(cargo --version)" == "$CARGO_VERSION" ]] || fail 'cargo version does not match the frozen builder'
[[ "${JOBS:-1}" =~ ^[1-9][0-9]*$ ]] || fail 'JOBS must be a positive integer'

git_repository cat-file -e "${SOURCE_COMMIT}^{commit}" \
  || fail 'frozen downstream source commit is unavailable'
git_repository merge-base --is-ancestor "$SOURCE_COMMIT" HEAD \
  || fail 'frozen downstream source commit is not an ancestor of HEAD'
git_repository diff --quiet "$SOURCE_COMMIT" -- codex-rs \
  || fail 'codex-rs tracked source differs from the frozen downstream commit'
[[ -z "$(git_repository ls-files --others --exclude-standard -- codex-rs)" ]] \
  || fail 'codex-rs contains untracked source files'
verify_sha256 "$REPOSITORY_ROOT/codex-rs/Cargo.lock" "$CARGO_LOCK_SHA256" 'downstream Cargo.lock'
verify_sha256 "$REPOSITORY_ROOT/codex-rs/rust-toolchain.toml" "$RUST_TOOLCHAIN_SHA256" 'Rust toolchain file'
python3 - "$REPOSITORY_ROOT/codex-rs/Cargo.toml" <<'PY'
import sys
import tomllib
from pathlib import Path

workspace = tomllib.loads(Path(sys.argv[1]).read_text())
if workspace.get("workspace", {}).get("package", {}).get("version") != "0.144.4":
    raise SystemExit("Codex workspace version is not frozen at 0.144.4")
PY

readonly V8_CHECKSUMS="$V8_ROOT/rusty-v8-artifacts.sha256"
mapfile -t V8_HASHES < <(python3 - "$V8_ROOT" "$V8_CHECKSUMS" <<'PY'
import gzip
import hashlib
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
manifest = Path(sys.argv[2])
names = (
    "librusty_v8_release_aarch64-linux-android.a",
    "librusty_v8_release_aarch64-linux-android.a.gz",
    "src_binding_release_aarch64-linux-android.rs",
)
if not manifest.is_file() or manifest.is_symlink():
    raise SystemExit("rusty_v8 checksum manifest is missing or is a symlink")

declared = {}
for line in manifest.read_text().splitlines():
    match = re.fullmatch(r"([0-9a-f]{64})  ([^\0]+)", line)
    if not match:
        raise SystemExit(f"invalid rusty_v8 checksum row: {line!r}")
    name = Path(match.group(2)).name
    if name not in names or name in declared:
        raise SystemExit(f"unexpected or duplicate rusty_v8 artifact: {name}")
    declared[name] = match.group(1)
if set(declared) != set(names):
    raise SystemExit("rusty_v8 checksum manifest has an incomplete artifact set")

for name in names:
    path = root / name
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"rusty_v8 artifact is missing or is a symlink: {name}")
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != declared[name]:
        raise SystemExit(f"rusty_v8 artifact hash mismatch: {name}")

plain_hash = hashlib.sha256()
with gzip.open(root / names[1], "rb") as stream:
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        plain_hash.update(block)
if plain_hash.hexdigest() != declared[names[0]]:
    raise SystemExit("compressed rusty_v8 archive does not expand to the verified archive")

print(hashlib.sha256(manifest.read_bytes()).hexdigest())
for name in names:
    print(declared[name])
PY
)
[[ "${#V8_HASHES[@]}" == 4 ]] || fail 'failed to read verified rusty_v8 artifact hashes'
readonly V8_MANIFEST_SHA256="${V8_HASHES[0]}"
readonly V8_ARCHIVE_SHA256="${V8_HASHES[1]}"
readonly V8_ARCHIVE_GZIP_SHA256="${V8_HASHES[2]}"
readonly V8_BINDING_SHA256="${V8_HASHES[3]}"
[[ "$V8_ARCHIVE_SHA256" == "$V8_ARCHIVE_EXPECTED_SHA256" \
  && "$V8_ARCHIVE_GZIP_SHA256" == "$V8_ARCHIVE_GZIP_EXPECTED_SHA256" \
  && "$V8_BINDING_SHA256" == "$V8_BINDING_EXPECTED_SHA256" ]] \
  || fail 'rusty_v8 artifacts differ from the frozen output hashes'
readonly V8_PREPARED_BINDING="$SCRATCH_DIR/$V8_BINDING_NAME"
"$SCRIPT_DIR/prepare-rusty-v8-binding.sh" \
  "$V8_ROOT/$V8_BINDING_NAME" "$V8_PREPARED_BINDING"
[[ "$(file_size "$V8_ROOT/$V8_BINDING_NAME")" -gt 1024 ]] \
  || fail 'rusty_v8 binding file is unexpectedly small'
archive_member_count=0
while IFS= read -r archive_member; do
  [[ -n "$archive_member" ]] || continue
  case "$archive_member" in
    /*|../*|*/../*|*/..)
      fail "rusty_v8 archive contains an unsafe member path: $archive_member"
      ;;
  esac
  archive_member_count=$((archive_member_count + 1))
done < <("$AR" t "$V8_ROOT/$V8_ARCHIVE_NAME")
[[ "$archive_member_count" -gt 0 ]] || fail 'rusty_v8 static archive is empty'

unset CARGO_ENCODED_RUSTFLAGS CARGO_TARGET_DIR RUSTC RUSTC_WRAPPER \
  RUSTC_WORKSPACE_WRAPPER RUSTFLAGS RUSTY_V8_MIRROR V8_FROM_SOURCE
export ANDROID_NDK_HOME="$NDK_HOME"
export ANDROID_NDK_ROOT="$NDK_HOME"
export AR_aarch64_linux_android="$NDK_BIN/llvm-ar"
export CC_aarch64_linux_android="$NDK_BIN/aarch64-linux-android29-clang"
export CXX_aarch64_linux_android="$NDK_BIN/aarch64-linux-android29-clang++"
export RANLIB_aarch64_linux_android="$NDK_BIN/llvm-ranlib"
export CARGO_HOME="$CARGO_HOME_PATH"
export CARGO_INCREMENTAL=0
export CARGO_NET_OFFLINE=true
export CARGO_TARGET_DIR="$TARGET_DIR"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="--remap-path-prefix=${REPOSITORY_ROOT}=/usr/src/codex -Clink-arg=-lc++_shared -Clink-arg=${BUILTINS_ARCHIVE} -Clink-arg=-Wl,--build-id=sha1"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export HOME="$BUILD_HOME"
export LIBLZMA_NO_PKG_CONFIG=1
export NUM_JOBS="${JOBS:-$(nproc)}"
export OPENSSL_NO_PKG_CONFIG=1
export PATH="$NDK_BIN:/opt/rust/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PKG_CONFIG_ALLOW_CROSS=1
export RUSTY_V8_ARCHIVE="$V8_ROOT/$V8_ARCHIVE_GZIP_NAME"
export RUSTY_V8_SRC_BINDING_PATH="$V8_PREPARED_BINDING"
export TMPDIR="$BUILD_TMP"
export ZERO_AR_DATE=1

(
  cd "$REPOSITORY_ROOT/codex-rs"
  cargo build \
    --package codex-cli \
    --bin codex \
    --release \
    --target "$TARGET" \
    --locked \
    --frozen \
    --offline
)

readonly BUILT_CODEX="$TARGET_DIR/$TARGET/release/codex"
[[ -f "$BUILT_CODEX" && ! -L "$BUILT_CODEX" && -x "$BUILT_CODEX" ]] \
  || fail 'Cargo did not produce the Codex CLI binary'
mkdir -p "$PACKAGE_DIR/bin"
install -m 0755 "$BUILT_CODEX" "$PACKAGE_DIR/bin/codex"
"$STRIP" --strip-all "$PACKAGE_DIR/bin/codex"
verify_elf "$PACKAGE_DIR/bin/codex" 'packaged Codex CLI'

mapfile -t NEEDED_LIBRARIES < <(
  "$READELF" --dynamic --wide "$PACKAGE_DIR/bin/codex" \
    | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' \
    | sort -u
)
[[ "${#NEEDED_LIBRARIES[@]}" -gt 0 ]] || fail 'packaged Codex CLI has no DT_NEEDED entries'
has_libc=false
has_libcxx=false
for needed_library in "${NEEDED_LIBRARIES[@]}"; do
  case "$needed_library" in
    libc.so)
      has_libc=true
      ;;
    libc++_shared.so)
      has_libcxx=true
      ;;
    libdl.so|liblog.so|libm.so)
      ;;
    *)
      fail "packaged Codex CLI has an unexpected DT_NEEDED entry: $needed_library"
      ;;
  esac
done
[[ "$has_libc" == true ]] || fail 'packaged Codex CLI is not linked against Android libc'

if [[ "$has_libcxx" == true ]]; then
  readonly LIBCXX_SOURCE="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"
  [[ -f "$LIBCXX_SOURCE" && ! -L "$LIBCXX_SOURCE" ]] \
    || fail 'Codex requires libc++_shared.so but the pinned NDK copy is unavailable'
  install -m 0644 "$LIBCXX_SOURCE" "$PACKAGE_DIR/bin/libc++_shared.so"
  "$STRIP" --strip-all "$PACKAGE_DIR/bin/libc++_shared.so"
  verify_shared_library "$PACKAGE_DIR/bin/libc++_shared.so" 'packaged libc++_shared.so'
fi

install -m 0644 "$REPOSITORY_ROOT/LICENSE" "$PACKAGE_DIR/LICENSE"
install -m 0644 "$REPOSITORY_ROOT/NOTICE" "$PACKAGE_DIR/NOTICE"
build_id="$($READELF --notes --wide "$PACKAGE_DIR/bin/codex" \
  | sed -n 's/.*Build ID: //p' | head -n 1)"
[[ "$build_id" =~ ^[0-9a-f]{40}$ ]] || fail 'packaged Codex CLI has no SHA-1 ELF build ID'

python3 - "$PACKAGE_DIR" "$V8_MANIFEST_SHA256" "$V8_ARCHIVE_SHA256" \
  "$V8_ARCHIVE_GZIP_SHA256" "$V8_BINDING_SHA256" \
  "$V8_PREPARED_BINDING_SHA256" "$build_id" \
  "${NEEDED_LIBRARIES[@]}" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

package_dir = Path(sys.argv[1])
v8_manifest, v8_archive, v8_archive_gzip, v8_binding, v8_prepared_binding, build_id = sys.argv[2:8]
needed = sys.argv[8:]


def file_record(path: Path) -> dict[str, object]:
    relative = path.relative_to(package_dir).as_posix()
    mode = stat.S_IMODE(path.stat().st_mode)
    return {
        "path": relative,
        "mode": f"{mode:04o}",
        "size": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


files = [package_dir / "bin/codex", package_dir / "LICENSE", package_dir / "NOTICE"]
libcxx = package_dir / "bin/libc++_shared.so"
if libcxx.exists():
    files.append(libcxx)
files.sort(key=lambda path: path.relative_to(package_dir).as_posix())

manifest = {
    "schemaVersion": 1,
    "artifactId": "happy-codex-android-aarch64-v0.144.4",
    "promotionStatus": "unapproved_poc",
    "version": "0.144.4",
    "target": {
        "triple": "aarch64-linux-android",
        "abi": "arm64-v8a",
        "androidApiLevel": 29,
    },
    "source": {
        "repository": "https://github.com/openai/codex",
        "upstreamTag": "rust-v0.144.4",
        "upstreamCommit": "8c68d4c87dc54d38861f5114e920c3de2efa5876",
        "downstreamCommit": "ab9c3ec845b913c2a9adf23a60c4d04f65c647b1",
        "cargoLockSha256": "221542fd6c8d48fec346a6684cadc7bcbc110fa2a0f7f2e574b22523e0ef5f75",
    },
    "build": {
        "rustVersion": "1.95.0",
        "androidNdkVersion": "28.2.13676358",
        "sourceDateEpoch": 1784002837,
        "rustyV8": {
            "version": "149.2.0",
            "commit": "5d0e31ea6bf67f4559faa759b91e22bc3f1cd696",
            "artifactManifestSha256": v8_manifest,
            "archiveSha256": v8_archive,
            "archiveGzipSha256": v8_archive_gzip,
            "bindingSha256": v8_binding,
            "preparedBindingSha256": v8_prepared_binding,
        },
    },
    "elf": {
        "class": "ELF64",
        "machine": "AArch64",
        "interpreter": "/system/bin/linker64",
        "buildId": build_id,
        "needed": needed,
    },
    "files": [file_record(path) for path in files],
}
(package_dir / "artifact-manifest.json").write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n"
)
PY

checksum_files=(LICENSE NOTICE artifact-manifest.json bin/codex)
if [[ "$has_libcxx" == true ]]; then
  checksum_files+=(bin/libc++_shared.so)
fi
(
  cd "$PACKAGE_DIR"
  printf '%s\n' "${checksum_files[@]}" | sort \
    | while IFS= read -r checksum_file; do
      sha256sum "$checksum_file"
    done > SHA256SUMS
  sha256sum --check --strict SHA256SUMS >/dev/null
)

archive_partial="$SCRATCH_DIR/$ARCHIVE_NAME"
tar --create \
  --directory "$OUTPUT_ROOT" \
  --sort=name \
  --format=posix \
  --mtime="@$SOURCE_DATE_EPOCH" \
  --clamp-mtime \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  --pax-option=delete=atime,delete=ctime \
  "$PACKAGE_ROOT_NAME" \
  | gzip --best --no-name > "$archive_partial"
[[ -s "$archive_partial" ]] || fail 'Codex package archive is empty'
mv "$archive_partial" "$ARCHIVE_PATH"
(
  cd "$OUTPUT_ROOT"
  sha256sum "$ARCHIVE_NAME" > "${ARCHIVE_NAME}.sha256"
  sha256sum --check --strict "${ARCHIVE_NAME}.sha256" >/dev/null
)

printf 'verified Codex Android package: %s\n' "$ARCHIVE_PATH"
printf 'archive SHA-256: %s\n' "$(file_sha256 "$ARCHIVE_PATH")"
printf 'Codex ELF SHA-256: %s\n' "$(file_sha256 "$PACKAGE_DIR/bin/codex")"
printf 'Codex ELF build ID: %s\n' "$build_id"
printf 'DT_NEEDED: %s\n' "$(IFS=,; printf '%s' "${NEEDED_LIBRARIES[*]}")"
