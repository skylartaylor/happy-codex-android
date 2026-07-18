use std::fs::File;
use std::fs::OpenOptions;
use std::io::Read;
use std::io::Result;
use std::io::Seek;
use std::io::SeekFrom;
use std::io::Write;

#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use codex_utils_absolute_path::AbsolutePathBuf;
use tokio::fs;
use uuid::Uuid;

pub(crate) const INSTALLATION_ID_FILENAME: &str = "installation_id";

#[cfg(target_os = "android")]
static INSTALLATION_ID_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[cfg(target_os = "android")]
fn lock_installation_id_file(file: &File) -> Result<()> {
    use std::os::fd::AsRawFd;

    // `std::fs::File::lock` is unsupported on Android. POSIX record locks are
    // available and preserve the required cross-process serialization.
    let mut lock: libc::flock = unsafe { std::mem::zeroed() };
    lock.l_type = libc::F_WRLCK as _;
    lock.l_whence = libc::SEEK_SET as _;

    loop {
        // SAFETY: `file` owns a valid descriptor, and `lock` remains valid for
        // the duration of the blocking `fcntl` call.
        if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETLKW, &lock) } == 0 {
            return Ok(());
        }

        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

#[cfg(not(target_os = "android"))]
fn lock_installation_id_file(file: &File) -> Result<()> {
    file.lock()
}

pub async fn resolve_installation_id(codex_home: &AbsolutePathBuf) -> Result<String> {
    let path = codex_home.join(INSTALLATION_ID_FILENAME);
    fs::create_dir_all(codex_home).await?;
    tokio::task::spawn_blocking(move || {
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true);

        #[cfg(unix)]
        {
            options.mode(0o644);
        }

        // POSIX record locks are process-associated, so Android also needs a
        // mutex to serialize callers within this process. Declaring the guard
        // before `file` ensures the descriptor (and its record lock) is
        // released first.
        #[cfg(target_os = "android")]
        let _process_guard = INSTALLATION_ID_LOCK
            .lock()
            .map_err(|_| std::io::Error::other("installation ID lock poisoned"))?;

        let mut file = options.open(&path)?;
        lock_installation_id_file(&file)?;

        #[cfg(unix)]
        {
            let metadata = file.metadata()?;
            let current_mode = metadata.permissions().mode() & 0o777;
            if current_mode != 0o644 {
                let mut permissions = metadata.permissions();
                permissions.set_mode(0o644);
                file.set_permissions(permissions)?;
            }
        }

        let mut contents = String::new();
        file.read_to_string(&mut contents)?;
        let trimmed = contents.trim();
        if !trimmed.is_empty()
            && let Ok(existing) = Uuid::parse_str(trimmed)
        {
            return Ok(existing.to_string());
        }

        let installation_id = Uuid::new_v4().to_string();
        file.set_len(0)?;
        file.seek(SeekFrom::Start(0))?;
        file.write_all(installation_id.as_bytes())?;
        file.flush()?;
        file.sync_all()?;

        Ok(installation_id)
    })
    .await?
}

#[cfg(test)]
mod tests {
    use super::INSTALLATION_ID_FILENAME;
    use super::resolve_installation_id;
    use core_test_support::PathExt;
    use futures::future::join_all;
    use pretty_assertions::assert_eq;
    use tempfile::TempDir;
    use uuid::Uuid;

    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    #[tokio::test]
    async fn resolve_installation_id_generates_and_persists_uuid() {
        let codex_home = TempDir::new().expect("create temp dir");
        let codex_home_abs = codex_home.path().abs();
        let persisted_path = codex_home.path().join(INSTALLATION_ID_FILENAME);

        let installation_id = resolve_installation_id(&codex_home_abs)
            .await
            .expect("resolve installation id");

        assert_eq!(
            std::fs::read_to_string(&persisted_path).expect("read persisted installation id"),
            installation_id
        );
        assert!(Uuid::parse_str(&installation_id).is_ok());

        #[cfg(unix)]
        {
            let mode = std::fs::metadata(&persisted_path)
                .expect("read installation id metadata")
                .permissions()
                .mode()
                & 0o777;
            assert_eq!(mode, 0o644);
        }
    }

    #[tokio::test]
    async fn resolve_installation_id_reuses_existing_uuid() {
        let codex_home = TempDir::new().expect("create temp dir");
        let codex_home_abs = codex_home.path().abs();
        let existing = Uuid::new_v4().to_string().to_uppercase();
        std::fs::write(
            codex_home.path().join(INSTALLATION_ID_FILENAME),
            existing.clone(),
        )
        .expect("write installation id");

        let resolved = resolve_installation_id(&codex_home_abs)
            .await
            .expect("resolve installation id");

        assert_eq!(
            resolved,
            Uuid::parse_str(existing.as_str())
                .expect("parse existing installation id")
                .to_string()
        );
    }

    #[tokio::test]
    async fn resolve_installation_id_rewrites_invalid_file_contents() {
        let codex_home = TempDir::new().expect("create temp dir");
        let codex_home_abs = codex_home.path().abs();
        std::fs::write(
            codex_home.path().join(INSTALLATION_ID_FILENAME),
            "not-a-uuid",
        )
        .expect("write invalid installation id");

        let resolved = resolve_installation_id(&codex_home_abs)
            .await
            .expect("resolve installation id");

        assert!(Uuid::parse_str(&resolved).is_ok());
        assert_eq!(
            std::fs::read_to_string(codex_home.path().join(INSTALLATION_ID_FILENAME))
                .expect("read rewritten installation id"),
            resolved
        );
    }

    #[tokio::test]
    async fn resolve_installation_id_serializes_concurrent_writers() {
        let codex_home = TempDir::new().expect("create temp dir");
        let codex_home_abs = codex_home.path().abs();

        let resolved = join_all((0..16).map(|_| resolve_installation_id(&codex_home_abs)))
            .await
            .into_iter()
            .collect::<Result<Vec<_>, _>>()
            .expect("resolve concurrent installation ids");

        assert!(resolved.iter().all(|id| id == &resolved[0]));
        assert_eq!(
            std::fs::read_to_string(codex_home.path().join(INSTALLATION_ID_FILENAME))
                .expect("read persisted installation id"),
            resolved[0]
        );
    }
}
