use std::process::Command;

use crate::enforcement::{ServiceControlOperation, validate_systemd_service_name};
use crate::{OsmanthusError, Result};

const SYSTEMCTL: &str = "/usr/bin/systemctl";

pub fn require_canonical_service(unit: &str) -> Result<()> {
    validate_systemd_service_name(unit)?;
    let output = Command::new(SYSTEMCTL)
        .args(["show", "--property=Id", "--property=LoadState", "--", unit])
        .output()?;
    if !output.status.success() {
        return Err(OsmanthusError::InvalidState(format!(
            "systemd service does not exist or cannot be loaded: {unit}"
        )));
    }
    let properties = std::str::from_utf8(&output.stdout).map_err(|_| {
        OsmanthusError::InvalidState("systemctl returned non-UTF-8 output".to_owned())
    })?;
    let (canonical, load_state) = parse_service_properties(properties)?;
    validate_systemd_service_name(canonical)?;
    if canonical != unit {
        return Err(OsmanthusError::InvalidState(format!(
            "service aliases are not accepted; use canonical unit {canonical}"
        )));
    }
    if !matches!(load_state, "loaded" | "masked") {
        return Err(OsmanthusError::InvalidState(format!(
            "systemd service does not exist or cannot be loaded: {unit}"
        )));
    }
    Ok(())
}

fn parse_service_properties(properties: &str) -> Result<(&str, &str)> {
    let mut canonical = None;
    let mut load_state = None;
    for line in properties.lines() {
        if let Some(value) = line.strip_prefix("Id=") {
            canonical = Some(value);
        } else if let Some(value) = line.strip_prefix("LoadState=") {
            load_state = Some(value);
        }
    }
    match (canonical, load_state) {
        (Some(canonical), Some(load_state)) => Ok((canonical, load_state)),
        _ => Err(OsmanthusError::InvalidState(
            "systemctl did not return complete service identity".to_owned(),
        )),
    }
}

pub fn request(unit: &str, operation: ServiceControlOperation) -> Result<()> {
    validate_systemd_service_name(unit)?;
    let output = Command::new(SYSTEMCTL)
        .args([
            "--no-ask-password",
            "--no-block",
            operation.systemctl_verb(),
            "--",
            unit,
        ])
        .output()?;
    if output.status.success() {
        return Ok(());
    }
    let message = String::from_utf8_lossy(&output.stderr);
    let message = message.trim();
    Err(OsmanthusError::InvalidState(if message.is_empty() {
        format!(
            "systemd rejected {} for {unit} with {}",
            operation.systemctl_verb(),
            output.status
        )
    } else {
        format!(
            "systemd rejected {} for {unit}: {message}",
            operation.systemctl_verb()
        )
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_labeled_service_identity() {
        assert_eq!(
            parse_service_properties("Id=postgresql.service\nLoadState=loaded\n").unwrap(),
            ("postgresql.service", "loaded")
        );
        assert!(parse_service_properties("Id=postgresql.service\n").is_err());
    }
}
