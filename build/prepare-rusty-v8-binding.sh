#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
umask 022

readonly SOURCE_SHA256='cded03dd9deb0c84ec46f7d2f38da837e9ca551dacb8abb4ea8bd07fc312b7f9'
readonly PREPARED_SHA256='c03bb6bd234eda46b5591d9411825c8cedfe603f8e58c4bea49fe756b97396bb'
readonly NULL_TERMINATE='v8_String_WriteFlags_kNullTerminate'
readonly REPLACE_INVALID_UTF8='v8_String_WriteFlags_kReplaceInvalidUtf8'

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s SOURCE_BINDING PREPARED_BINDING\n' "${0##*/}" >&2
  exit 2
}

count_literal() {
  grep --only-matching --fixed-strings "$2" "$1" \
    | wc -l | tr -d '[:space:]' || true
}

[[ $# -eq 2 ]] || usage
for command_name in cat grep install sha256sum tr wc; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "required command is unavailable: $command_name"
done

readonly SOURCE_BINDING="$1"
readonly PREPARED_BINDING="$2"
[[ -f "$SOURCE_BINDING" && ! -L "$SOURCE_BINDING" ]] \
  || fail 'source rusty_v8 binding is missing or is not a regular file'
[[ ! -e "$PREPARED_BINDING" && ! -L "$PREPARED_BINDING" ]] \
  || fail 'prepared rusty_v8 binding path already exists'
printf '%s  %s\n' "$SOURCE_SHA256" "$SOURCE_BINDING" \
  | sha256sum --check --strict - >/dev/null \
  || fail 'source rusty_v8 binding differs from the frozen artifact'

[[ "$(count_literal "$SOURCE_BINDING" 'WriteFlags_kNullTerminate')" == 1 \
  && "$(count_literal "$SOURCE_BINDING" 'WriteFlags_kReplaceInvalidUtf8')" == 1 \
  && "$(count_literal "$SOURCE_BINDING" "$NULL_TERMINATE")" == 0 \
  && "$(count_literal "$SOURCE_BINDING" "$REPLACE_INVALID_UTF8")" == 0 ]] \
  || fail 'source rusty_v8 binding has unexpected WriteFlags declarations'

install -m 0644 "$SOURCE_BINDING" "$PREPARED_BINDING"
cat >> "$PREPARED_BINDING" <<'EOF'


// Android bindgen 0.72 emits these anonymous-enum constants without the
// namespace-qualified names expected by the v8 crate.
pub const v8_String_WriteFlags_kNullTerminate: WriteFlags__bindgen_ty_1 = WriteFlags_kNullTerminate;
pub const v8_String_WriteFlags_kReplaceInvalidUtf8: WriteFlags__bindgen_ty_1 = WriteFlags_kReplaceInvalidUtf8;
EOF
printf '%s  %s\n' "$PREPARED_SHA256" "$PREPARED_BINDING" \
  | sha256sum --check --strict - >/dev/null \
  || fail 'prepared rusty_v8 binding differs from the frozen Android transform'

printf 'prepared rusty_v8 Android binding at %s\n' "$PREPARED_BINDING"
