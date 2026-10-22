use std::ffi::{CStr, OsStr};
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;

use uuid::Uuid;

use crate::{OsmanthusError, Result};

pub const OSMANTHUS_SHELL: &str = "/usr/bin/osmanthus-shell";
const USERMOD: &str = "/usr/sbin/usermod";
const SYSTEM_SHELLS: &str = "/etc/shells";
const MAX_NSS_BUFFER: usize = 1_048_576;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SystemAccount {
    pub name: String,
    pub shell: PathBuf,
}

pub fn account(uid: u32) -> Result<SystemAccount> {
    if uid == 0 {
        return Err(OsmanthusError::InvalidState(
            "root cannot be enrolled as a monitored login identity".to_owned(),
        ));
    }
    let initial = unsafe { libc::sysconf(libc::_SC_GETPW_R_SIZE_MAX) };
    let mut size = usize::try_from(initial).unwrap_or(16_384).max(1_024);
    loop {
        let mut record = unsafe { std::mem::zeroed::<libc::passwd>() };
        let mut result = std::ptr::null_mut();
        let mut buffer = vec![0_u8; size];
        let status = unsafe {
            libc::getpwuid_r(
                uid,
                &mut record,
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                &mut result,
            )
        };
        if status == libc::ERANGE && size < MAX_NSS_BUFFER {
            size = (size * 2).min(MAX_NSS_BUFFER);
            continue;
        }
        if status != 0 {
            return Err(std::io::Error::from_raw_os_error(status).into());
        }
        if result.is_null() {
            return Err(OsmanthusError::InvalidState(format!(
                "operating-system UID does not exist: {uid}"
            )));
        }
        let name = unsafe { CStr::from_ptr(record.pw_name) }
            .to_str()
            .map_err(|_| OsmanthusError::InvalidState("account name is not UTF-8".to_owned()))?
            .to_owned();
        let shell = unsafe { CStr::from_ptr(record.pw_shell) }.to_bytes();
        return Ok(SystemAccount {
            name,
            shell: PathBuf::from(OsStr::from_bytes(shell)),
        });
    }
}

pub fn validate_osmanthus_shell() -> Result<()> {
    validate_executable(Path::new(OSMANTHUS_SHELL), "Osmanthus login shell")
}

pub fn validate_real_shell(path: &Path) -> Result<()> {
    validate_executable(path, "real login shell")
}

pub fn ensure_registered() -> Result<()> {
    update_registration(Path::new(SYSTEM_SHELLS), 0, true)
}

pub fn unregister() -> Result<()> {
    update_registration(Path::new(SYSTEM_SHELLS), 0, false)
}

fn update_registration(path: &Path, expected_uid: u32, register: bool) -> Result<()> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.uid() != expected_uid
        || metadata.permissions().mode() & 0o022 != 0
        || metadata.len() > 65_536
    {
        return Err(OsmanthusError::UnsafePath(format!(
            "{} must be owned by uid {expected_uid}, non-writable by group/others, regular, and at most 64 KiB",
            path.display()
        )));
    }
    let mut contents = String::new();
    file.read_to_string(&mut contents)?;
    let present = contents.lines().any(|line| line.trim() == OSMANTHUS_SHELL);
    if present == register {
        return Ok(());
    }

    let replacement = if register {
        if !contents.ends_with('\n') && !contents.is_empty() {
            contents.push('\n');
        }
        contents.push_str(OSMANTHUS_SHELL);
        contents.push('\n');
        contents
    } else {
        contents
            .split_inclusive('\n')
            .filter(|line| line.trim() != OSMANTHUS_SHELL)
            .collect()
    };
    replace_shells_file(path, &metadata, replacement.as_bytes())
}

fn replace_shells_file(path: &Path, original: &fs::Metadata, contents: &[u8]) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| OsmanthusError::UnsafePath(path.display().to_string()))?;
    let temporary = parent.join(format!(".osmanthus-shells-{}.tmp", Uuid::new_v4()));
    let result = (|| -> Result<()> {
        let mode = original.permissions().mode() & 0o7777;
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&temporary)?;
        let temporary_metadata = file.metadata()?;
        if temporary_metadata.uid() != original.uid() || temporary_metadata.gid() != original.gid()
        {
            let status = unsafe {
                libc::fchown(
                    file.as_raw_fd(),
                    original.uid() as libc::uid_t,
                    original.gid() as libc::gid_t,
                )
            };
            if status != 0 {
                return Err(std::io::Error::last_os_error().into());
            }
        }
        fs::set_permissions(&temporary, fs::Permissions::from_mode(mode))?;
        file.write_all(contents)?;
        file.sync_all()?;

        let current = fs::symlink_metadata(path)?;
        if current.file_type().is_symlink()
            || !current.is_file()
            || current.dev() != original.dev()
            || current.ino() != original.ino()
        {
            return Err(OsmanthusError::InvalidState(format!(
                "{} changed while updating login-shell registration",
                path.display()
            )));
        }
        fs::rename(&temporary, path)?;
        fs::File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

pub fn set_shell(uid: u32, expected: &Path, replacement: &Path) -> Result<()> {
    let before = account(uid)?;
    if before.shell == replacement {
        return Ok(());
    }
    if before.shell != expected {
        return Err(OsmanthusError::InvalidState(format!(
            "UID {uid} login shell changed concurrently: expected {}, found {}",
            expected.display(),
            before.shell.display()
        )));
    }
    validate_executable(replacement, "replacement login shell")?;
    validate_executable(Path::new(USERMOD), "usermod")?;
    let output = Command::new(USERMOD)
        .arg("--shell")
        .arg(replacement)
        .arg(&before.name)
        .output()?;
    if !output.status.success() {
        let message = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        return Err(OsmanthusError::Execution(format!(
            "usermod failed for UID {uid}{}",
            if message.is_empty() {
                String::new()
            } else {
                format!(": {message}")
            }
        )));
    }
    let after = account(uid)?;
    if after.shell != replacement {
        return Err(OsmanthusError::InvalidState(format!(
            "UID {uid} login shell was not updated to {}",
            replacement.display()
        )));
    }
    Ok(())
}

fn validate_executable(path: &Path, label: &str) -> Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    let mode = metadata.permissions().mode();
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.uid() != 0
        || mode & 0o111 == 0
        || mode & 0o022 != 0
    {
        return Err(OsmanthusError::UnsafePath(format!(
            "{label} must be a root-owned, non-writable executable file: {}",
            path.display()
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use tempfile::TempDir;

    use super::*;

    #[test]
    fn resolves_the_current_non_root_account_without_mutating_it() {
        let uid = unsafe { libc::getuid() };
        if uid == 0 {
            return;
        }
        let account = account(uid).unwrap();
        assert!(!account.name.is_empty());
        assert!(account.shell.is_absolute());
    }

    #[test]
    fn refuses_root_enrollment() {
        assert!(account(0).is_err());
    }

    #[test]
    fn registration_is_idempotent_and_removable_without_changing_file_metadata() {
        let temp = TempDir::new().unwrap();
        let shells = temp.path().join("shells");
        fs::write(&shells, b"# managed shells\n/bin/sh\n/bin/bash").unwrap();
        fs::set_permissions(&shells, fs::Permissions::from_mode(0o644)).unwrap();
        let before = fs::metadata(&shells).unwrap();
        let uid = before.uid();

        update_registration(&shells, uid, true).unwrap();
        update_registration(&shells, uid, true).unwrap();
        let registered = fs::read_to_string(&shells).unwrap();
        assert_eq!(registered.matches(OSMANTHUS_SHELL).count(), 1);
        assert_eq!(
            registered,
            "# managed shells\n/bin/sh\n/bin/bash\n/usr/bin/osmanthus-shell\n"
        );

        update_registration(&shells, uid, false).unwrap();
        update_registration(&shells, uid, false).unwrap();
        assert_eq!(
            fs::read_to_string(&shells).unwrap(),
            "# managed shells\n/bin/sh\n/bin/bash\n"
        );
        let after = fs::metadata(&shells).unwrap();
        assert_eq!(after.uid(), before.uid());
        assert_eq!(after.gid(), before.gid());
        assert_eq!(after.permissions().mode() & 0o7777, 0o644);
    }

    #[test]
    fn registration_rejects_symlinked_or_group_writable_shell_files() {
        let temp = TempDir::new().unwrap();
        let target = temp.path().join("target");
        let shells = temp.path().join("shells");
        fs::write(&target, b"/bin/sh\n").unwrap();
        std::os::unix::fs::symlink(&target, &shells).unwrap();
        let uid = fs::metadata(&target).unwrap().uid();
        assert!(update_registration(&shells, uid, true).is_err());

        fs::remove_file(&shells).unwrap();
        fs::write(&shells, b"/bin/sh\n").unwrap();
        fs::set_permissions(&shells, fs::Permissions::from_mode(0o664)).unwrap();
        assert!(update_registration(&shells, uid, true).is_err());
    }
}
