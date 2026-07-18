#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
umask 022

readonly RUSTY_V8_COMMIT='5d0e31ea6bf67f4559faa759b91e22bc3f1cd696'
readonly ANDROID_PLATFORM_COMMIT='e3919359f2387399042d31401817db4a02d756ec'
readonly CATAPULT_COMMIT='5a34891efa6e41c8aca8842386b8ee528963ffdf'
readonly NDK_SHA256='dfb20d396df28ca02a8c708314b814a4d961dc9074f9a161932746f815aa552f'
readonly NDK_SIZE='722261334'
readonly GN_ARCHIVE_SHA256='1eccf93c9e58b8b277b66932ab124e21b18191d065a0d65149b2e7522db4e5f0'
readonly GN_ARCHIVE_SIZE='3458216'
readonly GN_BINARY_SHA256='9a45b0aabd427540f2cc05f3d81ac964873fa4ba618698751c1db48f8d09b524'
readonly NINJA_ARCHIVE_SHA256='3f1f1cc0f69a1bcfdf67fb6c2bc7419b1dd812bb8d0e79afa9bfa8a3553b5082'
readonly NINJA_ARCHIVE_SIZE='182403'
readonly NINJA_BINARY_SHA256='09f0e5a8a2cf762b24b4d3ed464ffb2529e650d2efc36bab31da36aa93791efc'
readonly CHROMIUM_RUST_TOOLCHAIN_SHA256='a96863c5b811af23cbe3f20fcfc82939e637be2bd79f05a117f1762c3bb35fe5'
readonly CHROMIUM_RUST_TOOLCHAIN_SIZE='274625900'
readonly CHROMIUM_LIBCLANG_FILENAME='lib/libclang.so.23.0.0git'
readonly CHROMIUM_LIBCLANG_SIZE='107641056'
readonly CHROMIUM_LIBCLANG_SONAME_LINK='libclang.so.23.0git'
readonly CHROMIUM_LIBCLANG_LINK='libclang.so'
readonly CHROMIUM_CLANG_TOOLCHAIN_SHA256='f4569980affeb46176ea13dbf3e6dc7d41848c4b73207bfc143575925fca0452'
readonly CHROMIUM_CLANG_TOOLCHAIN_SIZE='69665364'
readonly CHROMIUM_CLANG_TOOLCHAIN_VERSION='llvmorg-23-init-10931-g20b6ec66-3'
readonly SYSROOT_SHA256='52d61d4446ffebfaa3dda2cd02da4ab4876ff237853f46d273e7f9b666652e1d'
readonly SYSROOT_SIZE='19727236'
readonly SUBMODULE_LOCK_SHA256='a2e79ba15ab1f59e5701ca8ca9eb4d7a5bd613d6b4f421f5220fc2977499d9dd'
readonly TARGET_ENV_SHA256='1524456f7a6daab6e433248056dc136730a608d2e7f3079405927d636d0e15d3'
readonly RUSTC_VERSION='rustc 1.95.0 (59807616e 2026-04-14)'
readonly CARGO_VERSION='cargo 1.95.0 (f2d3ce0bd 2026-03-21)'
readonly RUSTY_V8_SOURCE_DATE_EPOCH='1779728126'
readonly RUSTY_V8_CARGO_LOCK_SHA256='ae9a372644c9f04bc33c11c121ec7a7fcf510e7f8173246621f621850c5735ae'
readonly RUSTY_V8_CARGO_TOML_SHA256='b2e08fc9d277cd79811e87105861ba61b07ab20d1fbaf9c0be91fddd1f68bb4b'
readonly V8_ARCHIVE_EXPECTED_SHA256='aff3c75ff060e77319d93fc34483a0947b4bc2ad9d8597b9f9c44444857b91de'
readonly V8_ARCHIVE_GZIP_EXPECTED_SHA256='b396d07e5a390a264ac3a696d94b3ea465c9d19b4c60088b27c73aaf268457f0'
readonly V8_BINDING_EXPECTED_SHA256='cded03dd9deb0c84ec46f7d2f38da837e9ca551dacb8abb4ea8bd07fc312b7f9'

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s INPUT_ROOT OUTPUT_ROOT\n' "${0##*/}" >&2
  exit 2
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

  [[ -f "$path" && ! -L "$path" ]] || fail "$label is missing or is not a regular file"
  [[ "$(file_size "$path")" == "$expected_size" ]] || fail "$label has the wrong byte size"
  printf '%s  %s\n' "$expected_sha256" "$path" | sha256sum --check --strict - >/dev/null \
    || fail "$label failed SHA-256 verification"
}

write_expected_submodules() {
  awk '
    NF != 2 || length($1) != 40 || $1 ~ /[^0-9a-f]/ { exit 1 }
    { print $2, $1 }
  ' "$SUBMODULE_LOCK_PATH" || fail 'rusty_v8 submodule lock has an invalid row'
}

verify_submodule_lock() {
  local source_dir="$1"
  local scratch_dir expected_paths declared_paths path commit

  while IFS=' ' read -r path commit; do
    [[ -d "$source_dir/$path" ]] || fail "missing rusty_v8 submodule: $path"
    [[ "$(git -C "$source_dir/$path" rev-parse HEAD)" == "$commit" ]] \
      || fail "rusty_v8 submodule is at an unexpected commit: $path"
    [[ -z "$(git -C "$source_dir/$path" status --porcelain)" ]] \
      || fail "rusty_v8 submodule is dirty before build preparation: $path"
  done < <(write_expected_submodules)

  scratch_dir="$(mktemp -d)"
  expected_paths="$scratch_dir/expected-paths"
  declared_paths="$scratch_dir/declared-paths"
  write_expected_submodules | cut -d ' ' -f 1 | sort > "$expected_paths"
  git -C "$source_dir" config --file .gitmodules --get-regexp '^submodule\..*\.path$' \
    | awk '{print $2}' | sort > "$declared_paths"
  if ! diff --unified "$expected_paths" "$declared_paths"; then
    rm -rf "$scratch_dir"
    fail 'rusty_v8 .gitmodules declares an unexpected submodule set'
  fi
  rm -rf "$scratch_dir"
}

patch_android_ndk_version() {
  local config_path="$1"
  local root_line='  android_ndk_root = "//third_party/android_toolchain/ndk"'
  local version_line='  android_ndk_version = "r28"'

  if grep --fixed-strings --line-regexp "$version_line" "$config_path" >/dev/null; then
    return
  fi
  [[ "$(grep --fixed-strings --line-regexp --count "$root_line" "$config_path")" == 1 ]] \
    || fail 'unable to locate the unique Android NDK root declaration'
  [[ "$(grep --fixed-strings --count 'android_ndk_version =' "$config_path")" == 0 ]] \
    || fail 'an unexpected Android NDK version declaration already exists'
  sed --in-place "/android_ndk_root =/a\\${version_line}" "$config_path"
  grep --fixed-strings --line-regexp "$version_line" "$config_path" >/dev/null \
    || fail 'failed to add the pinned Android NDK version declaration'
}

patch_binding_aliases() {
  local binding_path="$1"
  local first='pub const v8_String_WriteFlags_kNullTerminate: WriteFlags__bindgen_ty_1 = WriteFlags_kNullTerminate;'
  local second='pub const v8_String_WriteFlags_kReplaceInvalidUtf8: WriteFlags__bindgen_ty_1 = WriteFlags_kReplaceInvalidUtf8;'

  if grep --fixed-strings --line-regexp "$first" "$binding_path" >/dev/null \
    || grep --fixed-strings --line-regexp "$second" "$binding_path" >/dev/null; then
    if ! grep --fixed-strings --line-regexp "$first" "$binding_path" >/dev/null \
      || ! grep --fixed-strings --line-regexp "$second" "$binding_path" >/dev/null; then
      fail 'rusty_v8 binding aliases are only partially present'
    fi
    return
  fi

  cat >> "$binding_path" <<'EOF'

// Android bindgen 0.72 emits these anonymous-enum constants without the
// namespace-qualified names expected by the v8 crate.
pub const v8_String_WriteFlags_kNullTerminate: WriteFlags__bindgen_ty_1 = WriteFlags_kNullTerminate;
pub const v8_String_WriteFlags_kReplaceInvalidUtf8: WriteFlags__bindgen_ty_1 = WriteFlags_kReplaceInvalidUtf8;
EOF
}

[[ $# -eq 2 ]] || usage
[[ "$(uname -s)" == 'Linux' && "$(uname -m)" == 'x86_64' ]] \
  || fail 'rusty_v8 must be built on Linux x86_64'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
readonly SUBMODULE_LOCK_PATH="${RUSTY_V8_SUBMODULE_LOCK:-$SCRIPT_DIR/rusty-v8-submodules.lock}"
readonly TARGET_ENV_PATH="${ANDROID_TARGET_ENV:-$SCRIPT_DIR/android-target.env}"
[[ -f "$SUBMODULE_LOCK_PATH" && ! -L "$SUBMODULE_LOCK_PATH" ]] \
  || fail 'rusty_v8 submodule lock is unavailable'
printf '%s  %s\n' "$SUBMODULE_LOCK_SHA256" "$SUBMODULE_LOCK_PATH" \
  | sha256sum --check --strict - >/dev/null \
  || fail 'rusty_v8 submodule lock failed SHA-256 verification'
[[ "$(wc -l < "$SUBMODULE_LOCK_PATH" | tr -d '[:space:]')" == 20 ]] \
  || fail 'rusty_v8 submodule lock must contain exactly 20 entries'
[[ -f "$TARGET_ENV_PATH" && ! -L "$TARGET_ENV_PATH" ]] \
  || fail 'Android target environment is unavailable'
printf '%s  %s\n' "$TARGET_ENV_SHA256" "$TARGET_ENV_PATH" \
  | sha256sum --check --strict - >/dev/null \
  || fail 'Android target environment failed SHA-256 verification'
set -a
# shellcheck source=/dev/null
source "$TARGET_ENV_PATH"
set +a
[[ "${ANDROID_TARGET_TRIPLE:-}" == 'aarch64-linux-android' ]] \
  || fail 'Android target environment has an unexpected target triple'
[[ "${ANDROID_API_LEVEL:-}" == 29 && "${ANDROID_NDK_VERSION:-}" == '28.2.13676358' ]] \
  || fail 'Android target environment has an unexpected API level or NDK version'
[[ "${RUST_VERSION:-}" == '1.95.0' && "${SOURCE_DATE_EPOCH:-}" == '1784002837' ]] \
  || fail 'Android target environment has an unexpected Rust version or source epoch'
readonly TARGET="$ANDROID_TARGET_TRIPLE"
[[ "$(rustc --version)" == "$RUSTC_VERSION" ]] || fail 'rustc version does not match the frozen builder'
[[ "$(cargo --version)" == "$CARGO_VERSION" ]] || fail 'cargo version does not match the frozen builder'
[[ "${JOBS:-1}" =~ ^[1-9][0-9]*$ ]] || fail 'JOBS must be a positive integer'

INPUT_ROOT="$(cd "$1" && pwd -P)"
readonly INPUT_ROOT
OUTPUT_ROOT="$(canonical_directory "$2")"
readonly OUTPUT_ROOT
readonly DOWNLOAD_DIR="$INPUT_ROOT/downloads"
readonly RUSTY_V8_SOURCE="$INPUT_ROOT/src/rusty_v8"
readonly NDK_HOME="$INPUT_ROOT/android-ndk-r28c"
readonly GN="$INPUT_ROOT/tools/gn/gn"
readonly NINJA_BINARY="$INPUT_ROOT/tools/ninja/ninja"
readonly CHROMIUM_RUST_TOOLCHAIN="$RUSTY_V8_SOURCE/third_party/rust-toolchain"
readonly CHROMIUM_CLANG_TOOLCHAIN="$INPUT_ROOT/tools/chromium-clang"
readonly SYSROOT_DIR="$INPUT_ROOT/sysroots/debian_bullseye_amd64-sysroot"
readonly TARGET_DIR="$INPUT_ROOT/target"
readonly CARGO_CACHE_DIR="$INPUT_ROOT/cargo-home"

[[ -f "$INPUT_ROOT/.complete" ]] || fail 'input root was not finalized by fetch-inputs.sh'
[[ -d "$CARGO_CACHE_DIR/registry" && -d "$CARGO_CACHE_DIR/git" ]] \
  || fail 'persistent Cargo input cache is incomplete'
[[ -f "$CARGO_CACHE_DIR/.codex-cargo-fetch-complete" ]] \
  || fail 'Codex Cargo input marker is missing'
(cd "$INPUT_ROOT" && sha256sum --check --strict inputs.lock.sha256 >/dev/null) \
  || fail 'input lock checksum is invalid'
[[ "$(git -C "$RUSTY_V8_SOURCE" rev-parse HEAD)" == "$RUSTY_V8_COMMIT" ]] \
  || fail 'rusty_v8 checkout is at an unexpected commit'
printf '%s  %s\n' "$RUSTY_V8_CARGO_LOCK_SHA256" "$RUSTY_V8_SOURCE/Cargo.lock" \
  | sha256sum --check --strict - >/dev/null || fail 'rusty_v8 Cargo.lock failed verification'
printf '%s  %s\n' "$RUSTY_V8_CARGO_TOML_SHA256" "$RUSTY_V8_SOURCE/Cargo.toml" \
  | sha256sum --check --strict - >/dev/null || fail 'rusty_v8 Cargo.toml failed verification'
[[ -z "$(git -C "$RUSTY_V8_SOURCE" status --porcelain --untracked-files=no)" ]] \
  || fail 'rusty_v8 tracked source is dirty before build preparation'
verify_submodule_lock "$RUSTY_V8_SOURCE"
[[ "$(git -C "$RUSTY_V8_SOURCE/third_party/android_platform" rev-parse HEAD)" == "$ANDROID_PLATFORM_COMMIT" ]] \
  || fail 'Android platform checkout is at an unexpected commit'
[[ -z "$(git -C "$RUSTY_V8_SOURCE/third_party/android_platform" status --porcelain)" ]] \
  || fail 'Android platform checkout is dirty'
[[ "$(git -C "$RUSTY_V8_SOURCE/third_party/catapult" rev-parse HEAD)" == "$CATAPULT_COMMIT" ]] \
  || fail 'Catapult checkout is at an unexpected commit'
[[ -z "$(git -C "$RUSTY_V8_SOURCE/third_party/catapult" status --porcelain)" ]] \
  || fail 'Catapult checkout is dirty'

verify_file "$DOWNLOAD_DIR/android-ndk-r28c-linux.zip" "$NDK_SHA256" "$NDK_SIZE" 'Android NDK r28c'
verify_file "$DOWNLOAD_DIR/gn.cipd" "$GN_ARCHIVE_SHA256" "$GN_ARCHIVE_SIZE" 'GN CIPD archive'
verify_file "$DOWNLOAD_DIR/ninja.cipd" "$NINJA_ARCHIVE_SHA256" "$NINJA_ARCHIVE_SIZE" 'Ninja CIPD archive'
verify_file "$DOWNLOAD_DIR/chromium-rust-toolchain.tar.xz" \
  "$CHROMIUM_RUST_TOOLCHAIN_SHA256" "$CHROMIUM_RUST_TOOLCHAIN_SIZE" \
  'Chromium Rust toolchain'
verify_file "$DOWNLOAD_DIR/chromium-clang-toolchain.tar.xz" \
  "$CHROMIUM_CLANG_TOOLCHAIN_SHA256" "$CHROMIUM_CLANG_TOOLCHAIN_SIZE" \
  'Chromium Clang toolchain'
verify_file "$DOWNLOAD_DIR/debian-bullseye-amd64-sysroot.tar.xz" \
  "$SYSROOT_SHA256" "$SYSROOT_SIZE" 'Chromium amd64 sysroot'
printf '%s  %s\n' "$GN_BINARY_SHA256" "$GN" | sha256sum --check --strict - >/dev/null \
  || fail 'GN binary failed verification'
printf '%s  %s\n' "$NINJA_BINARY_SHA256" "$NINJA_BINARY" | sha256sum --check --strict - >/dev/null \
  || fail 'Ninja binary failed verification'
grep --fixed-strings --line-regexp 'Pkg.Revision = 28.2.13676358' "$NDK_HOME/source.properties" >/dev/null \
  || fail 'extracted NDK has an unexpected revision'
[[ -x "$CHROMIUM_RUST_TOOLCHAIN/bin/rustc" \
  && -d "$CHROMIUM_RUST_TOOLCHAIN/lib/rustlib" \
  && -f "$CHROMIUM_RUST_TOOLCHAIN/$CHROMIUM_LIBCLANG_FILENAME" \
  && "$(file_size "$CHROMIUM_RUST_TOOLCHAIN/$CHROMIUM_LIBCLANG_FILENAME")" == "$CHROMIUM_LIBCLANG_SIZE" \
  && -L "$CHROMIUM_RUST_TOOLCHAIN/lib/$CHROMIUM_LIBCLANG_SONAME_LINK" \
  && "$(readlink "$CHROMIUM_RUST_TOOLCHAIN/lib/$CHROMIUM_LIBCLANG_SONAME_LINK")" == "${CHROMIUM_LIBCLANG_FILENAME##*/}" \
  && -L "$CHROMIUM_RUST_TOOLCHAIN/lib/$CHROMIUM_LIBCLANG_LINK" \
  && "$(readlink "$CHROMIUM_RUST_TOOLCHAIN/lib/$CHROMIUM_LIBCLANG_LINK")" == "$CHROMIUM_LIBCLANG_SONAME_LINK" ]] \
  || fail 'pinned Chromium Rust installation is incomplete'
[[ -x "$CHROMIUM_CLANG_TOOLCHAIN/bin/clang" \
  && -f "$CHROMIUM_CLANG_TOOLCHAIN/cr_build_revision" ]] \
  || fail 'pinned Chromium Clang installation is incomplete'
grep --fixed-strings --line-regexp "$CHROMIUM_CLANG_TOOLCHAIN_VERSION" \
  "$CHROMIUM_CLANG_TOOLCHAIN/cr_build_revision" >/dev/null \
  || fail 'pinned Chromium Clang installation has an unexpected revision'
[[ -d "$SYSROOT_DIR" && -f "$SYSROOT_DIR/.stamp" ]] \
  || fail 'pinned Chromium sysroot installation is incomplete'

readonly ANDROID_TOOLCHAIN_DIR="$RUSTY_V8_SOURCE/third_party/android_toolchain"
mkdir -p "$ANDROID_TOOLCHAIN_DIR"
[[ ! -e "$RUSTY_V8_SOURCE/third_party/android_ndk" ]] \
  || fail 'rusty_v8 Android NDK path already exists before preparation'
[[ ! -e "$ANDROID_TOOLCHAIN_DIR/ndk" ]] \
  || fail 'rusty_v8 Android toolchain NDK path already exists before preparation'
ln -s "$NDK_HOME" "$RUSTY_V8_SOURCE/third_party/android_ndk"
ln -s ../android_ndk "$ANDROID_TOOLCHAIN_DIR/ndk"

readonly BULLSEYE_SYSROOT_LINK="$RUSTY_V8_SOURCE/build/linux/debian_bullseye_amd64-sysroot"
readonly SID_SYSROOT_LINK="$RUSTY_V8_SOURCE/build/linux/debian_sid_amd64-sysroot"
[[ ! -e "$BULLSEYE_SYSROOT_LINK" && ! -L "$BULLSEYE_SYSROOT_LINK" ]] \
  || fail 'rusty_v8 Bullseye sysroot path already exists before preparation'
[[ ! -e "$SID_SYSROOT_LINK" && ! -L "$SID_SYSROOT_LINK" ]] \
  || fail 'rusty_v8 compatibility sysroot path already exists before preparation'
ln -s "$SYSROOT_DIR" "$BULLSEYE_SYSROOT_LINK"
ln -s "$SYSROOT_DIR" "$SID_SYSROOT_LINK"

patch_android_ndk_version "$RUSTY_V8_SOURCE/build/config/android/config.gni"
patch_binding_aliases "$RUSTY_V8_SOURCE/src/binding.rs"

readonly NDK_BIN="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
readonly BUILTINS_ARCHIVE="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/19/lib/linux/libclang_rt.builtins-aarch64-android.a"
[[ -x "$NDK_BIN/aarch64-linux-android29-clang" \
  && -f "$BUILTINS_ARCHIVE" ]] \
  || fail 'NDK compiler or compiler-rt builtins archive is missing'

# Pair libclang and clang from the same pinned Chromium LLVM revision. The Rust
# archive carries libclang while the smaller Clang archive carries the compiler
# binary and resource headers expected by rusty_v8's bindgen setup.
readonly BINDGEN_TOOLCHAIN="$TARGET_DIR/bindgen-toolchain"
[[ ! -e "$BINDGEN_TOOLCHAIN" ]] || fail 'bindgen toolchain path already exists'
mkdir -p "$BINDGEN_TOOLCHAIN/bin" "$BINDGEN_TOOLCHAIN/lib"
ln -s "$CHROMIUM_CLANG_TOOLCHAIN/bin/clang" "$BINDGEN_TOOLCHAIN/bin/clang"
ln -s "$CHROMIUM_RUST_TOOLCHAIN/lib/$CHROMIUM_LIBCLANG_LINK" \
  "$BINDGEN_TOOLCHAIN/lib/$CHROMIUM_LIBCLANG_LINK"

# The outer rusty_v8 bindgen invocation needs Android target flags. Chromium's
# nested host-side bindgen actions already receive complete GN-generated flags,
# so prevent the outer override from leaking across the Ninja process boundary.
readonly NINJA_WRAPPER="$TARGET_DIR/ninja-with-clean-bindgen-env"
mkdir -p "$TARGET_DIR"
{
  printf '#!/usr/bin/env bash\n'
  printf 'unset BINDGEN_EXTRA_CLANG_ARGS\n'
  printf 'exec %q "$@"\n' "$NINJA_BINARY"
} > "$NINJA_WRAPPER"
chmod 0755 "$NINJA_WRAPPER"

export ANDROID_NDK_HOME="$NDK_HOME"
export ANDROID_NDK_ROOT="$NDK_HOME"
export AR_aarch64_linux_android="$NDK_BIN/llvm-ar"
export CC_aarch64_linux_android="$NDK_BIN/aarch64-linux-android29-clang"
export CXX_aarch64_linux_android="$NDK_BIN/aarch64-linux-android29-clang++"
export RANLIB_aarch64_linux_android="$NDK_BIN/llvm-ranlib"
export CLANG_BASE_PATH="$CHROMIUM_CLANG_TOOLCHAIN"
export LIBCLANG_PATH="$BINDGEN_TOOLCHAIN/lib"
export BINDGEN_EXTRA_CLANG_ARGS="--target=aarch64-linux-android --sysroot=${NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
export GN
export NINJA="$NINJA_WRAPPER"
export V8_FROM_SOURCE=1
export CARGO_NET_OFFLINE=true
export CARGO_HOME="$CARGO_CACHE_DIR"
export CARGO_INCREMENTAL=0
export CARGO_TARGET_DIR="$TARGET_DIR"
export LIBLZMA_NO_PKG_CONFIG=1
export OPENSSL_NO_PKG_CONFIG=1
export PKG_CONFIG_ALLOW_CROSS=1
export SOURCE_DATE_EPOCH="$RUSTY_V8_SOURCE_DATE_EPOCH"
export ZERO_AR_DATE=1
export NUM_JOBS="${JOBS:-$(nproc)}"
export RUSTFLAGS="--remap-path-prefix=${RUSTY_V8_SOURCE}=/usr/src/rusty_v8"
export PATH="$NDK_BIN:$PATH"

cargo build \
  --manifest-path "$RUSTY_V8_SOURCE/Cargo.toml" \
  --lib --release --target "$TARGET" --locked --offline

archive="$(find "$TARGET_DIR/$TARGET/release/gn_out/obj" \
  -type f -name librusty_v8.a -print -quit)"
binding="$TARGET_DIR/$TARGET/release/gn_out/src_binding.rs"
[[ -n "$archive" && -f "$archive" ]] || fail 'librusty_v8.a was not produced'
[[ -f "$binding" ]] || fail 'src_binding.rs was not produced'

install -m 0644 "$archive" \
  "$OUTPUT_ROOT/librusty_v8_release_aarch64-linux-android.a"
install -m 0644 "$binding" \
  "$OUTPUT_ROOT/src_binding_release_aarch64-linux-android.rs"
gzip --no-name --keep --force \
  "$OUTPUT_ROOT/librusty_v8_release_aarch64-linux-android.a"
printf '%s  %s\n' "$V8_ARCHIVE_EXPECTED_SHA256" \
  "$OUTPUT_ROOT/librusty_v8_release_aarch64-linux-android.a" \
  | sha256sum --check --strict - >/dev/null \
  || fail 'librusty_v8.a differs from the frozen output hash'
printf '%s  %s\n' "$V8_ARCHIVE_GZIP_EXPECTED_SHA256" \
  "$OUTPUT_ROOT/librusty_v8_release_aarch64-linux-android.a.gz" \
  | sha256sum --check --strict - >/dev/null \
  || fail 'compressed librusty_v8.a differs from the frozen output hash'
printf '%s  %s\n' "$V8_BINDING_EXPECTED_SHA256" \
  "$OUTPUT_ROOT/src_binding_release_aarch64-linux-android.rs" \
  | sha256sum --check --strict - >/dev/null \
  || fail 'rusty_v8 binding differs from the frozen output hash'
sha256sum \
  "$OUTPUT_ROOT/librusty_v8_release_aarch64-linux-android.a" \
  "$OUTPUT_ROOT/librusty_v8_release_aarch64-linux-android.a.gz" \
  "$OUTPUT_ROOT/src_binding_release_aarch64-linux-android.rs" \
  > "$OUTPUT_ROOT/rusty-v8-artifacts.sha256"

printf 'verified rusty_v8 Android artifacts are ready at %s\n' "$OUTPUT_ROOT"
