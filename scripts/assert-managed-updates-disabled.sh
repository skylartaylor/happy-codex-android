#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

require_literal() {
  local file="$1"
  local literal="$2"
  if ! grep -Fq -- "$literal" "$file"; then
    echo "$file is missing required Android update guard: $literal" >&2
    exit 1
  fi
}

reject_literal() {
  local file="$1"
  local literal="$2"
  if grep -Fq -- "$literal" "$file"; then
    echo "$file contains forbidden managed-update text: $literal" >&2
    exit 1
  fi
}

require_literal codex-rs/app-server-daemon/src/lib.rs '#[path = "update_loop_android.rs"]'
require_literal codex-rs/app-server-daemon/src/lib.rs \
  'auto_update_enabled: cfg!(not(target_os = "android"))'
require_literal codex-rs/app-server-daemon/src/lib.rs \
  'return Ok(self.running_backend_instance(settings).await?.is_some());'
require_literal codex-rs/app-server-daemon/src/lib.rs \
  $'updater.stop().await?;\n        }\n        #[cfg(not(target_os = "android"))]\n        updater.start().await?;'
require_literal codex-rs/app-server-daemon/src/update_loop_android.rs \
  'the app-server updater is managed by Happy on Android'

require_literal codex-rs/cli/src/doctor.rs '#[path = "doctor/updates_android.rs"]'
require_literal codex-rs/cli/src/doctor/updates_android.rs \
  'Codex updates are managed by Happy'
require_literal codex-rs/cli/src/main.rs \
  'Codex updates are managed by Happy on Android'

require_literal codex-rs/tui/src/lib.rs '#[path = "updates_android.rs"]'
require_literal codex-rs/tui/src/lib.rs '#[cfg(not(target_os = "android"))]'
require_literal codex-rs/tui/src/tooltips.rs '#[cfg(not(target_os = "android"))]'
require_literal codex-rs/tui/src/update_action.rs \
  '#[cfg(all(not(debug_assertions), target_os = "android"))]'
require_literal codex-rs/tui/src/update_action.rs \
  'pub fn get_update_action() -> Option<UpdateAction>'
require_literal codex-rs/tui/src/updates_android.rs \
  'pub fn get_upgrade_version(_config: &Config) -> Option<String>'
require_literal codex-rs/tui/src/updates_android.rs \
  'pub fn get_upgrade_version_for_popup(_config: &Config) -> Option<String>'

android_stubs=(
  codex-rs/app-server-daemon/src/update_loop_android.rs
  codex-rs/cli/src/doctor/updates_android.rs
  codex-rs/tui/src/updates_android.rs
)

for file in "${android_stubs[@]}"; do
  reject_literal "$file" 'http://'
  reject_literal "$file" 'https://'
  reject_literal "$file" '@latest'
  reject_literal "$file" 'npm install'
  reject_literal "$file" 'Command::new'
  reject_literal "$file" 'reqwest'
done

echo "PASS: Android managed-update source guards are present; runtime tests remain a release gate"
