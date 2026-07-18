#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s CODEX_ANDROID_ARCHIVE [ADB_SERIAL]\n' "${0##*/}" >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

host_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

[[ $# -ge 1 && $# -le 2 ]] || usage
require_command adb
require_command awk
require_command grep
require_command mktemp
require_command sed
require_command tar
require_command tr

archive="$1"
[[ -f "$archive" && ! -L "$archive" ]] || fail 'artifact archive is missing or is a symlink'

if [[ $# -eq 2 ]]; then
  serial="$2"
else
  mapfile_supported=false
  if [[ -n "${BASH_VERSION:-}" && "${BASH_VERSINFO[0]}" -ge 4 ]]; then
    mapfile_supported=true
  fi
  if [[ "$mapfile_supported" == true ]]; then
    mapfile -t devices < <(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')
  else
    devices=()
    while IFS= read -r device; do
      devices+=("$device")
    done < <(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')
  fi
  [[ "${#devices[@]}" -eq 1 ]] || fail 'connect exactly one authorized Android device or pass ADB_SERIAL'
  serial="${devices[0]}"
fi

adb_cmd=(adb -s "$serial")
[[ "$("${adb_cmd[@]}" get-state 2>/dev/null)" == device ]] \
  || fail "Android device is not ready: $serial"
"${adb_cmd[@]}" shell run-as com.termux /system/bin/id >/dev/null 2>&1 \
  || fail 'com.termux is not installed as a debuggable package; run-as is unavailable'

scratch="$(mktemp -d "${TMPDIR:-/tmp}/happy-codex-android.XXXXXX")"
cleanup() {
  rm -rf "$scratch"
}
trap cleanup EXIT

members="$scratch/archive-members"
tar -tzf "$archive" > "$members"
if grep -E '(^/|(^|/)\.\.(/|$))' "$members" >/dev/null; then
  fail 'artifact archive contains an unsafe member path'
fi
package_root="$(sed -n '1s#/.*##p' "$members")"
[[ "$package_root" =~ ^happy-codex-android-aarch64-v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail 'artifact archive has an unexpected package root'
grep -Fx "$package_root/bin/codex" "$members" >/dev/null \
  || fail 'artifact archive does not contain bin/codex'
grep -Fx "$package_root/SHA256SUMS" "$members" >/dev/null \
  || fail 'artifact archive does not contain SHA256SUMS'
has_libcxx=false
if grep -Fx "$package_root/bin/libc++_shared.so" "$members" >/dev/null; then
  has_libcxx=true
fi

tar -xzf "$archive" -C "$scratch"
package_dir="$scratch/$package_root"
(
  cd "$package_dir"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c SHA256SUMS >/dev/null
  else
    shasum -a 256 -c SHA256SUMS >/dev/null
  fi
)

prefix='/data/data/com.termux/files/usr'
home_dir='/data/data/com.termux/files/home'
remote_dir="$prefix/tmp/$package_root"
remote_codex="$remote_dir/codex"
remote_libcxx="$remote_dir/libc++_shared.so"
preload="$prefix/lib/libtermux-exec.so"
cert_file="$prefix/etc/tls/cert.pem"

"${adb_cmd[@]}" shell \
  "run-as com.termux /system/bin/sh -c 'umask 077; rm -rf \"$remote_dir\"; mkdir -p \"$remote_dir\"'"
"${adb_cmd[@]}" shell \
  "run-as com.termux /system/bin/sh -c 'umask 077; /system/bin/cat > \"$remote_codex\"'" \
  < "$package_dir/bin/codex"
"${adb_cmd[@]}" shell \
  "run-as com.termux /system/bin/chmod 700 \"$remote_codex\""

if [[ "$has_libcxx" == true ]]; then
  "${adb_cmd[@]}" shell \
    "run-as com.termux /system/bin/sh -c 'umask 077; /system/bin/cat > \"$remote_libcxx\"'" \
    < "$package_dir/bin/libc++_shared.so"
  "${adb_cmd[@]}" shell \
    "run-as com.termux /system/bin/chmod 700 \"$remote_libcxx\""
fi

mappings=("$package_dir/bin/codex:$remote_codex")
if [[ "$has_libcxx" == true ]]; then
  mappings+=("$package_dir/bin/libc++_shared.so:$remote_libcxx")
fi
for mapping in "${mappings[@]}"; do
  local_path="${mapping%%:*}"
  remote_path="${mapping#*:}"
  expected="$(host_sha256 "$local_path")"
  actual="$("${adb_cmd[@]}" shell \
    "run-as com.termux /system/bin/sha256sum \"$remote_path\"" \
    | tr -d '\r' | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || fail "device hash mismatch for ${remote_path##*/}"
done

"${adb_cmd[@]}" shell \
  "run-as com.termux /system/bin/env LD_LIBRARY_PATH=\"$remote_dir\" /system/bin/linker64 --list \"$remote_codex\"" \
  >/dev/null

termux_version="$("${adb_cmd[@]}" shell dumpsys package com.termux \
  | tr -d '\r' | sed -n 's/^[[:space:]]*versionName=//p' | head -n 1)"
[[ -n "$termux_version" ]] || termux_version=unknown

"${adb_cmd[@]}" shell \
  "run-as com.termux /system/bin/env \
    HOME=\"$home_dir\" \
    PREFIX=\"$prefix\" \
    TMPDIR=\"$prefix/tmp\" \
    PATH=\"$prefix/bin:/system/bin\" \
    LD_LIBRARY_PATH=\"$remote_dir\" \
    SHELL=\"$prefix/bin/bash\" \
    TERM=xterm-256color \
    TERMUX_VERSION=\"$termux_version\" \
    NPM_CONFIG_PREFIX=\"$prefix\" \
    SSL_CERT_FILE=\"$cert_file\" \
    CODEX_SELF_EXE=\"$remote_codex\" \
    HAPPY_CODEX_TERMUX_PRELOAD=\"$preload\" \
    LD_PRELOAD=\"$preload\" \
    \"$remote_codex\" --version"

printf 'PASS: Codex Android artifact is installed and executable in Termux at %s\n' "$remote_codex"
