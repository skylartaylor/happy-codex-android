use std::path::Path;

use anyhow::Result;

pub(crate) async fn run() -> Result<()> {
    anyhow::bail!("the app-server updater is managed by Happy on Android")
}

pub(crate) fn reexec_managed_updater(_managed_codex_bin: &Path) -> Result<()> {
    anyhow::bail!("the app-server updater is managed by Happy on Android")
}
