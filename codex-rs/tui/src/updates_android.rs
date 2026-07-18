#![cfg(not(debug_assertions))]

use crate::legacy_core::config::Config;

pub(crate) use crate::updates_cache::dismiss_version;

pub fn get_upgrade_version(_config: &Config) -> Option<String> {
    None
}

pub fn get_upgrade_version_for_popup(_config: &Config) -> Option<String> {
    None
}
