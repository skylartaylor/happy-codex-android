#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
umask 022

readonly RUSTY_V8_REPOSITORY='https://github.com/denoland/rusty_v8.git'
readonly RUSTY_V8_TAG='v149.2.0'
readonly RUSTY_V8_COMMIT='5d0e31ea6bf67f4559faa759b91e22bc3f1cd696'
readonly ANDROID_PLATFORM_REPOSITORY='https://chromium.googlesource.com/chromium/src/third_party/android_platform.git'
readonly ANDROID_PLATFORM_COMMIT='e3919359f2387399042d31401817db4a02d756ec'
readonly CATAPULT_REPOSITORY='https://chromium.googlesource.com/catapult.git'
readonly CATAPULT_COMMIT='5a34891efa6e41c8aca8842386b8ee528963ffdf'

readonly NDK_URL='https://dl.google.com/android/repository/android-ndk-r28c-linux.zip'
readonly NDK_SHA256='dfb20d396df28ca02a8c708314b814a4d961dc9074f9a161932746f815aa552f'
readonly NDK_SHA1='a7b54a5de87fecd125a17d54f73c446199e72a64'
readonly NDK_SIZE='722261334'

readonly GN_PACKAGE='gn/gn/linux-amd64'
readonly GN_INSTANCE='Hsz5PJ5YuLJ3tmkyqxJOIbGBkdBloNZRSbLnUi205fAC'
readonly GN_ARCHIVE_SHA256='1eccf93c9e58b8b277b66932ab124e21b18191d065a0d65149b2e7522db4e5f0'
readonly GN_ARCHIVE_SIZE='3458216'
readonly GN_BINARY_SHA256='9a45b0aabd427540f2cc05f3d81ac964873fa4ba618698751c1db48f8d09b524'

readonly NINJA_PACKAGE='infra/3pp/tools/ninja/linux-amd64'
readonly NINJA_INSTANCE='Px8cwPaaG8_fZ_tsK8dBmx3YEruNDnmvqb-oo1U7UIIC'
readonly NINJA_ARCHIVE_SHA256='3f1f1cc0f69a1bcfdf67fb6c2bc7419b1dd812bb8d0e79afa9bfa8a3553b5082'
readonly NINJA_ARCHIVE_SIZE='182403'
readonly NINJA_BINARY_SHA256='09f0e5a8a2cf762b24b4d3ed464ffb2529e650d2efc36bab31da36aa93791efc'

readonly CHROMIUM_RUST_TOOLCHAIN_OBJECT='Linux_x64/rust-toolchain-4c4205163abcbd08948b3efab796c543ba1ea687-2-llvmorg-23-init-10931-g20b6ec66.tar.xz'
readonly CHROMIUM_RUST_TOOLCHAIN_SHA256='a96863c5b811af23cbe3f20fcfc82939e637be2bd79f05a117f1762c3bb35fe5'
readonly CHROMIUM_RUST_TOOLCHAIN_SIZE='274625900'
readonly CHROMIUM_RUST_TOOLCHAIN_URL="https://storage.googleapis.com/chromium-browser-clang/${CHROMIUM_RUST_TOOLCHAIN_OBJECT}"
readonly CHROMIUM_CLANG_TOOLCHAIN_OBJECT='Linux_x64/clang-llvmorg-23-init-10931-g20b6ec66-3.tar.xz'
readonly CHROMIUM_CLANG_TOOLCHAIN_SHA256='f4569980affeb46176ea13dbf3e6dc7d41848c4b73207bfc143575925fca0452'
readonly CHROMIUM_CLANG_TOOLCHAIN_SIZE='69665364'
readonly CHROMIUM_CLANG_TOOLCHAIN_URL="https://commondatastorage.googleapis.com/chromium-browser-clang/${CHROMIUM_CLANG_TOOLCHAIN_OBJECT}"
readonly CHROMIUM_CLANG_TOOLCHAIN_VERSION='llvmorg-23-init-10931-g20b6ec66-3'

readonly SYSROOT_SHA256='52d61d4446ffebfaa3dda2cd02da4ab4876ff237853f46d273e7f9b666652e1d'
readonly SYSROOT_SIZE='19727236'
readonly SYSROOT_URL="https://commondatastorage.googleapis.com/chrome-linux-sysroot/${SYSROOT_SHA256}"
readonly SUBMODULE_LOCK_SHA256='a2e79ba15ab1f59e5701ca8ca9eb4d7a5bd613d6b4f421f5220fc2977499d9dd'
readonly RUSTC_VERSION='rustc 1.95.0 (59807616e 2026-04-14)'
readonly CARGO_VERSION='cargo 1.95.0 (f2d3ce0bd 2026-03-21)'
readonly RUSTY_V8_CARGO_LOCK_SHA256='ae9a372644c9f04bc33c11c121ec7a7fcf510e7f8173246621f621850c5735ae'
readonly RUSTY_V8_CARGO_TOML_SHA256='b2e08fc9d277cd79811e87105861ba61b07ab20d1fbaf9c0be91fddd1f68bb4b'

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s INPUT_ROOT CODEX_SOURCE_ROOT\n' "${0##*/}" >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

canonical_directory() {
  mkdir -p "$1"
  (cd "$1" && pwd -P)
}

file_size() {
  wc -c < "$1" | tr -d '[:space:]'
}

verify_file() {
  local path="$1"
  local expected_sha256="$2"
  local expected_size="$3"
  local label="$4"

  [[ -f "$path" && ! -L "$path" ]] || fail "$label is missing or is not a regular file: $path"
  [[ "$(file_size "$path")" == "$expected_size" ]] \
    || fail "$label has the wrong byte size"
  printf '%s  %s\n' "$expected_sha256" "$path" | sha256sum --check --strict - >/dev/null \
    || fail "$label failed SHA-256 verification"
}

download_verified() {
  local url="$1"
  local path="$2"
  local expected_sha256="$3"
  local expected_size="$4"
  local label="$5"
  local partial="${path}.partial"

  if [[ -e "$path" ]]; then
    verify_file "$path" "$expected_sha256" "$expected_size" "$label"
    return
  fi

  rm -f "$partial"
  curl --fail --location --proto '=https' --tlsv1.2 \
    --retry 3 --retry-all-errors --output "$partial" "$url"
  verify_file "$partial" "$expected_sha256" "$expected_size" "$label"
  mv "$partial" "$path"
}

fetch_cipd() {
  local package="$1"
  local instance="$2"
  local expected_sha256="$3"
  local expected_size="$4"
  local archive_path="$5"
  local label="$6"
  local response fetch_url
  local api_url='https://chrome-infra-packages.appspot.com/_ah/api/repo/v1/instance'

  response="$(curl --fail --get --proto '=https' --tlsv1.2 \
    --data-urlencode "package_name=${package}" \
    --data-urlencode "instance_id=${instance}" \
    "$api_url")"
  fetch_url="$(python3 -c '
import json
import sys

package, instance, digest = sys.argv[1:]
document = json.load(sys.stdin)
if document.get("status") != "SUCCESS":
    raise SystemExit("CIPD lookup did not succeed")
resolved = document.get("instance", {})
if resolved.get("package_name") != package or resolved.get("instance_id") != instance:
    raise SystemExit("CIPD lookup returned a different package or instance")
url = document.get("fetch_url", "")
expected_path = f"/store/SHA256/{digest}"
from urllib.parse import urlsplit
parsed = urlsplit(url)
if parsed.scheme != "https" or parsed.hostname != "storage.googleapis.com":
    raise SystemExit("CIPD lookup returned an unexpected fetch origin")
if not parsed.path.endswith(expected_path):
    raise SystemExit("CIPD fetch URL does not contain the pinned object digest")
print(url)
' "$package" "$instance" "$expected_sha256" <<<"$response")"

  download_verified "$fetch_url" "$archive_path" "$expected_sha256" "$expected_size" "$label"
}

clone_exact() {
  local repository="$1"
  local commit="$2"
  local destination="$3"
  local label="$4"
  local temporary="${destination}.partial"

  if [[ -e "$destination" ]]; then
    [[ -d "$destination/.git" ]] || fail "$label checkout is not a Git repository"
    [[ "$(git -C "$destination" rev-parse HEAD)" == "$commit" ]] \
      || fail "$label checkout is at an unexpected commit"
    [[ -z "$(git -C "$destination" status --porcelain)" ]] \
      || fail "$label checkout is dirty"
    return
  fi

  [[ ! -e "$temporary" ]] || fail "stale partial checkout exists: $temporary"
  git init --quiet "$temporary"
  git -C "$temporary" remote add origin "$repository"
  git -C "$temporary" fetch --quiet --depth 1 origin "$commit"
  git -C "$temporary" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
  [[ "$(git -C "$temporary" rev-parse HEAD)" == "$commit" ]] \
    || fail "$label fetch did not resolve to the pinned commit"
  mv "$temporary" "$destination"
}

write_expected_submodules() {
  awk '
    NF != 2 || length($1) != 40 || $1 ~ /[^0-9a-f]/ { exit 1 }
    { print $2, $1 }
  ' "$SUBMODULE_LOCK_PATH" || fail 'rusty_v8 submodule lock has an invalid row'
}

write_actual_submodules() {
  local source_dir="$1"
  local line marker payload commit path suffix

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    marker="${line:0:1}"
    [[ "$marker" == ' ' ]] || fail "submodule is uninitialized, conflicted, or modified: $line"
    payload="${line:1}"
    commit="${payload%% *}"
    suffix="${payload#* }"
    path="${suffix%% *}"
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "invalid submodule status: $line"
    printf '%s %s\n' "$path" "$commit"
  done < <(git -C "$source_dir" submodule status --recursive)
}

verify_submodule_lock() {
  local source_dir="$1"
  local scratch_dir expected actual expected_paths declared_paths

  scratch_dir="$(mktemp -d)"
  expected="$scratch_dir/expected"
  actual="$scratch_dir/actual"
  expected_paths="$scratch_dir/expected-paths"
  declared_paths="$scratch_dir/declared-paths"
  write_expected_submodules | sort > "$expected"
  write_actual_submodules "$source_dir" | sort > "$actual"
  if ! diff --unified "$expected" "$actual"; then
    rm -rf "$scratch_dir"
    fail 'rusty_v8 recursive submodule lock does not match the audited lock'
  fi

  cut -d ' ' -f 1 "$expected" | sort > "$expected_paths"
  git -C "$source_dir" config --file .gitmodules --get-regexp '^submodule\..*\.path$' \
    | awk '{print $2}' | sort > "$declared_paths"
  if ! diff --unified "$expected_paths" "$declared_paths"; then
    rm -rf "$scratch_dir"
    fail 'rusty_v8 .gitmodules declares an unexpected submodule set'
  fi

  rm -rf "$scratch_dir"
}

[[ $# -eq 2 ]] || usage
[[ "$(uname -s)" == 'Linux' && "$(uname -m)" == 'x86_64' ]] \
  || fail 'inputs must be fetched on Linux x86_64'

for command_name in awk cargo curl cut diff git gzip python3 rustc sha1sum sha256sum sort tar unzip wc xz; do
  require_command "$command_name"
done
[[ "$(rustc --version)" == "$RUSTC_VERSION" ]] || fail 'rustc version does not match the frozen builder'
[[ "$(cargo --version)" == "$CARGO_VERSION" ]] || fail 'cargo version does not match the frozen builder'
[[ "${FETCH_JOBS:-4}" =~ ^[1-9][0-9]*$ ]] || fail 'FETCH_JOBS must be a positive integer'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
readonly SUBMODULE_LOCK_PATH="${RUSTY_V8_SUBMODULE_LOCK:-$SCRIPT_DIR/rusty-v8-submodules.lock}"
readonly INPUTS_LOCK_PATH="${ANDROID_INPUTS_LOCK:-$SCRIPT_DIR/inputs.lock.json}"
[[ -f "$SUBMODULE_LOCK_PATH" && ! -L "$SUBMODULE_LOCK_PATH" ]] \
  || fail 'rusty_v8 submodule lock is unavailable'
[[ -f "$INPUTS_LOCK_PATH" && ! -L "$INPUTS_LOCK_PATH" ]] \
  || fail 'Android input manifest is unavailable'
printf '%s  %s\n' "$SUBMODULE_LOCK_SHA256" "$SUBMODULE_LOCK_PATH" \
  | sha256sum --check --strict - >/dev/null \
  || fail 'rusty_v8 submodule lock failed SHA-256 verification'
[[ "$(wc -l < "$SUBMODULE_LOCK_PATH" | tr -d '[:space:]')" == 20 ]] \
  || fail 'rusty_v8 submodule lock must contain exactly 20 entries'

INPUT_ROOT="$(canonical_directory "$1")"
readonly INPUT_ROOT
CODEX_SOURCE_ROOT="$(cd "$2" && pwd -P)"
readonly CODEX_SOURCE_ROOT
[[ -d "$CODEX_SOURCE_ROOT/.git" || -f "$CODEX_SOURCE_ROOT/.git" ]] \
  || fail 'Codex source root is not a Git checkout'

frozen_codex="$(python3 - "$INPUTS_LOCK_PATH" <<'PY'
import json
import sys
from pathlib import Path

lock = json.loads(Path(sys.argv[1]).read_text())
gate = lock["releaseGate"]
if gate.get("blockedUntilFrozen") is not False:
    raise SystemExit("downstream source gate is not frozen")
print(f'{gate["downstreamCommit"]}\t{gate["downstreamCargoLockSha256"]}')
PY
)"
IFS=$'\t' read -r CODEX_SOURCE_COMMIT CODEX_CARGO_LOCK_SHA256 <<<"$frozen_codex"
readonly CODEX_SOURCE_COMMIT CODEX_CARGO_LOCK_SHA256
git -c "safe.directory=$CODEX_SOURCE_ROOT" -C "$CODEX_SOURCE_ROOT" \
  merge-base --is-ancestor "$CODEX_SOURCE_COMMIT" HEAD \
  || fail 'Codex checkout does not contain the frozen Android source commit'
git -c "safe.directory=$CODEX_SOURCE_ROOT" -C "$CODEX_SOURCE_ROOT" \
  diff --quiet "$CODEX_SOURCE_COMMIT" -- codex-rs \
  || fail 'Codex Rust source differs from the frozen Android source commit'
[[ -z "$(git -c "safe.directory=$CODEX_SOURCE_ROOT" -C "$CODEX_SOURCE_ROOT" \
  status --porcelain --untracked-files=all -- codex-rs)" ]] \
  || fail 'Codex Rust source worktree is dirty'
printf '%s  %s\n' "$CODEX_CARGO_LOCK_SHA256" "$CODEX_SOURCE_ROOT/codex-rs/Cargo.lock" \
  | sha256sum --check --strict - >/dev/null \
  || fail 'Codex Cargo.lock failed frozen release-gate verification'

DOWNLOAD_DIR="$(canonical_directory "$INPUT_ROOT/downloads")"
readonly DOWNLOAD_DIR
SOURCE_ROOT="$(canonical_directory "$INPUT_ROOT/src")"
readonly SOURCE_ROOT
TOOL_ROOT="$(canonical_directory "$INPUT_ROOT/tools")"
readonly TOOL_ROOT
readonly RUSTY_V8_SOURCE="$SOURCE_ROOT/rusty_v8"
readonly CARGO_CACHE_DIR="$INPUT_ROOT/cargo-home"
mkdir -p "$CARGO_CACHE_DIR"
export CARGO_HOME="$CARGO_CACHE_DIR"

[[ ! -e "$INPUT_ROOT/.complete" ]] || fail 'input root is already finalized'

download_verified "$NDK_URL" "$DOWNLOAD_DIR/android-ndk-r28c-linux.zip" \
  "$NDK_SHA256" "$NDK_SIZE" 'Android NDK r28c'
printf '%s  %s\n' "$NDK_SHA1" "$DOWNLOAD_DIR/android-ndk-r28c-linux.zip" \
  | sha1sum --check --strict - >/dev/null \
  || fail 'Android NDK r28c failed its publisher SHA-1 verification'

fetch_cipd "$GN_PACKAGE" "$GN_INSTANCE" "$GN_ARCHIVE_SHA256" "$GN_ARCHIVE_SIZE" \
  "$DOWNLOAD_DIR/gn.cipd" 'GN CIPD archive'
fetch_cipd "$NINJA_PACKAGE" "$NINJA_INSTANCE" "$NINJA_ARCHIVE_SHA256" "$NINJA_ARCHIVE_SIZE" \
  "$DOWNLOAD_DIR/ninja.cipd" 'Ninja CIPD archive'

download_verified "$CHROMIUM_RUST_TOOLCHAIN_URL" \
  "$DOWNLOAD_DIR/chromium-rust-toolchain.tar.xz" \
  "$CHROMIUM_RUST_TOOLCHAIN_SHA256" "$CHROMIUM_RUST_TOOLCHAIN_SIZE" \
  'Chromium Rust toolchain'
download_verified "$CHROMIUM_CLANG_TOOLCHAIN_URL" \
  "$DOWNLOAD_DIR/chromium-clang-toolchain.tar.xz" \
  "$CHROMIUM_CLANG_TOOLCHAIN_SHA256" "$CHROMIUM_CLANG_TOOLCHAIN_SIZE" \
  'Chromium Clang toolchain'
download_verified "$SYSROOT_URL" "$DOWNLOAD_DIR/debian-bullseye-amd64-sysroot.tar.xz" \
  "$SYSROOT_SHA256" "$SYSROOT_SIZE" 'Chromium amd64 sysroot'

clone_exact "$RUSTY_V8_REPOSITORY" "$RUSTY_V8_COMMIT" "$RUSTY_V8_SOURCE" 'rusty_v8'
git -C "$RUSTY_V8_SOURCE" fetch --quiet --depth 1 origin \
  "refs/tags/${RUSTY_V8_TAG}:refs/tags/${RUSTY_V8_TAG}"
[[ "$(git -C "$RUSTY_V8_SOURCE" describe --tags --exact-match HEAD)" == "$RUSTY_V8_TAG" ]] \
  || fail 'rusty_v8 commit does not carry the expected exact tag'
printf '%s  %s\n' "$RUSTY_V8_CARGO_LOCK_SHA256" "$RUSTY_V8_SOURCE/Cargo.lock" \
  | sha256sum --check --strict - >/dev/null || fail 'rusty_v8 Cargo.lock failed verification'
printf '%s  %s\n' "$RUSTY_V8_CARGO_TOML_SHA256" "$RUSTY_V8_SOURCE/Cargo.toml" \
  | sha256sum --check --strict - >/dev/null || fail 'rusty_v8 Cargo.toml failed verification'

git -C "$RUSTY_V8_SOURCE" submodule sync --recursive
git -C "$RUSTY_V8_SOURCE" submodule update --init --recursive --depth 1 \
  --jobs "${FETCH_JOBS:-4}"
verify_submodule_lock "$RUSTY_V8_SOURCE"

clone_exact "$ANDROID_PLATFORM_REPOSITORY" "$ANDROID_PLATFORM_COMMIT" \
  "$RUSTY_V8_SOURCE/third_party/android_platform" 'Chromium Android platform'
clone_exact "$CATAPULT_REPOSITORY" "$CATAPULT_COMMIT" \
  "$RUSTY_V8_SOURCE/third_party/catapult" 'Chromium Catapult'

[[ ! -e "$TOOL_ROOT/gn" ]] || fail 'GN extraction directory already exists'
[[ ! -e "$TOOL_ROOT/ninja" ]] || fail 'Ninja extraction directory already exists'
mkdir "$TOOL_ROOT/gn" "$TOOL_ROOT/ninja"
unzip -q "$DOWNLOAD_DIR/gn.cipd" -d "$TOOL_ROOT/gn"
unzip -q "$DOWNLOAD_DIR/ninja.cipd" -d "$TOOL_ROOT/ninja"
chmod 0755 "$TOOL_ROOT/gn/gn" "$TOOL_ROOT/ninja/ninja"
printf '%s  %s\n' "$GN_BINARY_SHA256" "$TOOL_ROOT/gn/gn" \
  | sha256sum --check --strict - >/dev/null || fail 'extracted GN binary failed verification'
printf '%s  %s\n' "$NINJA_BINARY_SHA256" "$TOOL_ROOT/ninja/ninja" \
  | sha256sum --check --strict - >/dev/null || fail 'extracted Ninja binary failed verification'

[[ ! -e "$INPUT_ROOT/android-ndk-r28c" ]] || fail 'NDK extraction directory already exists'
unzip -q "$DOWNLOAD_DIR/android-ndk-r28c-linux.zip" -d "$INPUT_ROOT"
[[ -f "$INPUT_ROOT/android-ndk-r28c/source.properties" ]] \
  || fail 'NDK archive did not contain source.properties'
grep --fixed-strings --line-regexp 'Pkg.Revision = 28.2.13676358' \
  "$INPUT_ROOT/android-ndk-r28c/source.properties" >/dev/null \
  || fail 'extracted NDK has an unexpected revision'

readonly RUST_TOOLCHAIN_DIR="$RUSTY_V8_SOURCE/third_party/rust-toolchain"
[[ ! -e "$RUST_TOOLCHAIN_DIR" ]] || fail 'Chromium Rust toolchain directory already exists'
mkdir "$RUST_TOOLCHAIN_DIR"
tar --extract --xz --file "$DOWNLOAD_DIR/chromium-rust-toolchain.tar.xz" \
  --directory "$RUST_TOOLCHAIN_DIR" --no-same-owner
[[ -x "$RUST_TOOLCHAIN_DIR/bin/rustc" && -d "$RUST_TOOLCHAIN_DIR/lib/rustlib" ]] \
  || fail 'Chromium Rust toolchain is incomplete'
printf '%s' "$CHROMIUM_RUST_TOOLCHAIN_URL" > "$RUST_TOOLCHAIN_DIR/.rusty_v8_version"

readonly CLANG_TOOLCHAIN_DIR="$TOOL_ROOT/chromium-clang"
[[ ! -e "$CLANG_TOOLCHAIN_DIR" ]] || fail 'Chromium Clang toolchain directory already exists'
mkdir "$CLANG_TOOLCHAIN_DIR"
tar --extract --xz --file "$DOWNLOAD_DIR/chromium-clang-toolchain.tar.xz" \
  --directory "$CLANG_TOOLCHAIN_DIR" --no-same-owner
[[ -x "$CLANG_TOOLCHAIN_DIR/bin/clang" \
  && -f "$CLANG_TOOLCHAIN_DIR/cr_build_revision" ]] \
  || fail 'Chromium Clang toolchain is incomplete'
grep --fixed-strings --line-regexp "$CHROMIUM_CLANG_TOOLCHAIN_VERSION" \
  "$CLANG_TOOLCHAIN_DIR/cr_build_revision" >/dev/null \
  || fail 'Chromium Clang toolchain has an unexpected revision'
[[ -f "$INPUT_ROOT/android-ndk-r28c/toolchains/llvm/prebuilt/linux-x86_64/lib/libclang.so" ]] \
  || fail 'Android NDK libclang is unavailable for bindgen'

readonly SYSROOT_DIR="$INPUT_ROOT/sysroots/debian_bullseye_amd64-sysroot"
[[ ! -e "$SYSROOT_DIR" ]] || fail 'Chromium sysroot directory already exists'
mkdir -p "$SYSROOT_DIR"
tar --extract --xz --file "$DOWNLOAD_DIR/debian-bullseye-amd64-sysroot.tar.xz" \
  --directory "$SYSROOT_DIR" --no-same-owner
printf '%s' "$SYSROOT_URL" > "$SYSROOT_DIR/.stamp"

cargo fetch --manifest-path "$RUSTY_V8_SOURCE/Cargo.toml" \
  --locked --target aarch64-linux-android
cargo fetch --manifest-path "$CODEX_SOURCE_ROOT/codex-rs/Cargo.toml" \
  --locked --target aarch64-linux-android
cat > "$CARGO_CACHE_DIR/.codex-cargo-fetch-complete" <<EOF
schema_version=1
source_commit=${CODEX_SOURCE_COMMIT}
cargo_lock_sha256=${CODEX_CARGO_LOCK_SHA256}
target=aarch64-linux-android
cargo_version=1.95.0
EOF

cat > "$INPUT_ROOT/inputs.lock" <<EOF
rusty_v8_commit=${RUSTY_V8_COMMIT}
android_platform_commit=${ANDROID_PLATFORM_COMMIT}
catapult_commit=${CATAPULT_COMMIT}
ndk_sha256=${NDK_SHA256}
gn_cipd_instance=${GN_INSTANCE}
gn_archive_sha256=${GN_ARCHIVE_SHA256}
ninja_cipd_instance=${NINJA_INSTANCE}
ninja_archive_sha256=${NINJA_ARCHIVE_SHA256}
chromium_rust_toolchain_sha256=${CHROMIUM_RUST_TOOLCHAIN_SHA256}
chromium_clang_toolchain_sha256=${CHROMIUM_CLANG_TOOLCHAIN_SHA256}
sysroot_sha256=${SYSROOT_SHA256}
codex_source_commit=${CODEX_SOURCE_COMMIT}
codex_cargo_lock_sha256=${CODEX_CARGO_LOCK_SHA256}
EOF
(cd "$INPUT_ROOT" && sha256sum inputs.lock > inputs.lock.sha256)
touch "$INPUT_ROOT/.complete"

printf 'verified Android build inputs are ready at %s\n' "$INPUT_ROOT"
