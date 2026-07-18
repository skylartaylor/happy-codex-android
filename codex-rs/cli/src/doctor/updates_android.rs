use codex_core::config::Config;

use super::CheckStatus;
use super::DoctorCheck;

pub(super) fn updates_check(config: &Config) -> DoctorCheck {
    DoctorCheck::new(
        "updates.status",
        "updates",
        CheckStatus::Ok,
        "Codex updates are managed by Happy",
    )
    .details(vec![
        format!(
            "check for update on startup: {} (ignored)",
            config.check_for_update_on_startup
        ),
        "update action: managed by Happy".to_string(),
    ])
}
