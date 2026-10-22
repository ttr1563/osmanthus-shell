#[cfg(target_os = "linux")]
fn main() -> osmanthus_guard::Result<()> {
    use std::collections::BTreeSet;
    use std::fs::{self, OpenOptions};
    use std::io::Write;
    use std::path::{Path, PathBuf};

    use libbpf_rs::{Link, MapCore, MapFlags, MapHandle};
    use osmanthus_guard::daemon::EnforcementBackend;
    use osmanthus_guard::enforcement::{EnforcementPolicy, ProtectedAction, ProtectedRoot};
    use osmanthus_guard::linux_bpf::{PIN_DIRECTORY, PersistentLinuxBpfBackend};

    let mut arguments = std::env::args_os().skip(1);
    if arguments.next().as_deref() != Some(std::ffi::OsStr::new("--acknowledge-disposable-host")) {
        return Err(osmanthus_guard::OsmanthusError::InvalidState(
            "usage: bpf-persistence-smoke --acknowledge-disposable-host ABSOLUTE_EMPTY_TEST_DIRECTORY"
                .to_owned(),
        ));
    }
    let root = arguments.next().map(PathBuf::from).ok_or_else(|| {
        osmanthus_guard::OsmanthusError::InvalidState(
            "usage: bpf-persistence-smoke --acknowledge-disposable-host ABSOLUTE_EMPTY_TEST_DIRECTORY"
                .to_owned(),
        )
    })?;
    if arguments.next().is_some() {
        return Err(osmanthus_guard::OsmanthusError::InvalidState(
            "usage: bpf-persistence-smoke --acknowledge-disposable-host ABSOLUTE_EMPTY_TEST_DIRECTORY"
                .to_owned(),
        ));
    }
    if unsafe { libc::geteuid() } != 0 {
        return Err(osmanthus_guard::OsmanthusError::RootRequired);
    }
    if Path::new(PIN_DIRECTORY).exists() {
        return Err(osmanthus_guard::OsmanthusError::InvalidState(
            "persistence smoke test refuses an existing persistent Osmanthus backend".to_owned(),
        ));
    }
    if !root.is_absolute()
        || root == Path::new("/")
        || root.symlink_metadata()?.file_type().is_symlink()
    {
        return Err(osmanthus_guard::OsmanthusError::InvalidState(
            "persistence smoke root must be an existing canonical non-symlink directory other than /"
                .to_owned(),
        ));
    }
    let canonical_root = root.canonicalize()?;
    if canonical_root != root || !root.is_dir() {
        return Err(osmanthus_guard::OsmanthusError::InvalidState(
            "persistence smoke root must be an existing canonical non-symlink directory other than /"
                .to_owned(),
        ));
    }
    if root.read_dir()?.next().is_some() {
        return Err(osmanthus_guard::OsmanthusError::InvalidState(format!(
            "persistence smoke root must be empty: {}",
            root.display()
        )));
    }
    let file = root.join("blocked-after-loader-exit");
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&file)?
        .write_all(b"kept")?;
    let policy = EnforcementPolicy::new(vec![ProtectedRoot::new(
        &root,
        BTreeSet::from([ProtectedAction::Delete]),
    )?])?;

    let backend = PersistentLinuxBpfBackend::install_or_open(&policy)?;
    drop(backend);
    let before_upgrade = Link::open("/sys/fs/bpf/osmanthus/path_unlink")
        .map_err(|error| {
            osmanthus_guard::OsmanthusError::InvalidState(format!("open test BPF link: {error}"))
        })?
        .info()
        .map_err(|error| {
            osmanthus_guard::OsmanthusError::InvalidState(format!("inspect test BPF link: {error}"))
        })?
        .prog_id;
    match fs::remove_file(&file) {
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => {}
        Err(error) => return Err(error.into()),
        Ok(()) => {
            return Err(osmanthus_guard::OsmanthusError::InvalidState(
                "persistent BPF link did not block after loader exit".to_owned(),
            ));
        }
    }
    let reopened = PersistentLinuxBpfBackend::install_or_open(&policy)?;
    let after_upgrade = Link::open("/sys/fs/bpf/osmanthus/path_unlink")
        .map_err(|error| {
            osmanthus_guard::OsmanthusError::InvalidState(format!("reopen test BPF link: {error}"))
        })?
        .info()
        .map_err(|error| {
            osmanthus_guard::OsmanthusError::InvalidState(format!(
                "reinspect test BPF link: {error}"
            ))
        })?
        .prog_id;
    if before_upgrade == after_upgrade {
        return Err(osmanthus_guard::OsmanthusError::InvalidState(
            "persistent BPF program was not replaced in place".to_owned(),
        ));
    }
    drop(reopened);

    let metadata =
        MapHandle::from_pinned_path("/sys/fs/bpf/osmanthus/metadata").map_err(|error| {
            osmanthus_guard::OsmanthusError::InvalidState(format!(
                "open test BPF metadata map: {error}"
            ))
        })?;
    let mut legacy_truncate_link =
        Link::open("/sys/fs/bpf/osmanthus/inode_setattr").map_err(|error| {
            osmanthus_guard::OsmanthusError::InvalidState(format!(
                "open test inode-setattr BPF link: {error}"
            ))
        })?;
    legacy_truncate_link.unpin().map_err(|error| {
        osmanthus_guard::OsmanthusError::InvalidState(format!(
            "simulate the ABI 4 BPF link set: {error}"
        ))
    })?;
    metadata
        .update(&0_u32.to_ne_bytes(), &4_u32.to_ne_bytes(), MapFlags::ANY)
        .map_err(|error| {
            osmanthus_guard::OsmanthusError::InvalidState(format!(
                "write incompatible test BPF ABI: {error}"
            ))
        })?;
    let incompatible = PersistentLinuxBpfBackend::install_or_open(&policy);
    if !matches!(
        incompatible,
        Err(osmanthus_guard::OsmanthusError::InvalidState(message))
            if message.contains("BPF ABI is incompatible")
    ) {
        return Err(osmanthus_guard::OsmanthusError::InvalidState(
            "incompatible BPF ABI was not rejected".to_owned(),
        ));
    }
    match fs::remove_file(&file) {
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => {}
        Err(error) => return Err(error.into()),
        Ok(()) => {
            return Err(osmanthus_guard::OsmanthusError::InvalidState(
                "incompatible BPF ABI rejection detached existing enforcement".to_owned(),
            ));
        }
    }
    metadata
        .update(&0_u32.to_ne_bytes(), &5_u32.to_ne_bytes(), MapFlags::ANY)
        .map_err(|error| {
            osmanthus_guard::OsmanthusError::InvalidState(format!("restore test BPF ABI: {error}"))
        })?;
    legacy_truncate_link
        .pin("/sys/fs/bpf/osmanthus/inode_setattr")
        .map_err(|error| {
            osmanthus_guard::OsmanthusError::InvalidState(format!(
                "restore test inode-setattr BPF link: {error}"
            ))
        })?;
    drop(legacy_truncate_link);
    drop(metadata);

    let mut reopened = PersistentLinuxBpfBackend::install_or_open(&policy)?;
    reopened.decommission()?;
    drop(reopened);
    fs::remove_file(&file)?;
    if std::path::Path::new("/sys/fs/bpf/osmanthus").exists() {
        return Err(osmanthus_guard::OsmanthusError::InvalidState(
            "decommission left the persistent BPF directory behind".to_owned(),
        ));
    }
    println!(
        "Osmanthus persistent BPF smoke test passed: {}",
        root.display()
    );
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("the BPF persistence smoke test is available only on Linux");
    std::process::exit(1);
}
