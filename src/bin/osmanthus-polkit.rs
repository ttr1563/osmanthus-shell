use std::fs;

use osmanthus_guard::enforcement::{
    OSMANTHUSD_SERVICE, ServiceAction, service_operation_for_systemd_verb,
    validate_systemd_service_name,
};
use osmanthus_guard::protocol::{RequestBody, ResponseBody};
use osmanthus_guard::{OsmanthusError, Result, system_policy};

fn main() {
    let decision = evaluate(std::env::args().skip(1).collect());
    match decision {
        Ok(Decision::Pass) => println!("pass"),
        Ok(Decision::Deny) => println!("deny"),
        Err(error) => {
            eprintln!("osmanthus-polkit: {error}");
            println!("deny");
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Decision {
    Pass,
    Deny,
}

fn evaluate(arguments: Vec<String>) -> Result<Decision> {
    if unsafe { libc::geteuid() } != 0 {
        return Err(OsmanthusError::RootRequired);
    }
    let [unit, verb, pid] = arguments.as_slice() else {
        return Err(OsmanthusError::InvalidState(
            "expected UNIT VERB SUBJECT_PID".to_owned(),
        ));
    };
    validate_systemd_service_name(unit)?;
    let Some(operation) = service_operation_for_systemd_verb(verb) else {
        return Ok(Decision::Pass);
    };
    let self_stop =
        unit == OSMANTHUSD_SERVICE && operation.actions().contains(&ServiceAction::Stop);
    if !self_stop && system_policy::load()?.is_none() {
        return Ok(Decision::Pass);
    }

    let subject_pid = pid
        .parse::<u32>()
        .map_err(|_| OsmanthusError::InvalidState("Polkit subject PID is invalid".to_owned()))?;
    let subject_uid = subject_uid(subject_pid)?;
    match osmanthus_guard::daemon_client::request(RequestBody::ServiceControlDecision {
        unit: unit.clone(),
        operation,
        subject_uid,
        subject_pid,
    })? {
        ResponseBody::ServiceControlAllowed => Ok(Decision::Pass),
        ResponseBody::ServiceControlDenialRecorded => Ok(Decision::Deny),
        response => Err(OsmanthusError::InvalidState(format!(
            "unexpected daemon response: {response:?}"
        ))),
    }
}

fn subject_uid(pid: u32) -> Result<u32> {
    if pid == 0 {
        return Err(OsmanthusError::InvalidState(
            "Polkit subject PID must be nonzero".to_owned(),
        ));
    }
    let status = fs::read_to_string(format!("/proc/{pid}/status"))?;
    let uid = status
        .lines()
        .find_map(|line| line.strip_prefix("Uid:"))
        .and_then(|value| value.split_whitespace().next())
        .ok_or_else(|| OsmanthusError::InvalidState("Polkit subject UID is missing".to_owned()))?
        .parse::<u32>()
        .map_err(|_| OsmanthusError::InvalidState("Polkit subject UID is invalid".to_owned()))?;
    if uid == 0 {
        return Err(OsmanthusError::InvalidState(
            "root service-control does not use Polkit mediation".to_owned(),
        ));
    }
    Ok(uid)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_process_uid_is_read_from_proc() {
        let current_uid = unsafe { libc::getuid() };
        if current_uid == 0 {
            assert!(subject_uid(std::process::id()).is_err());
        } else {
            assert_eq!(subject_uid(std::process::id()).unwrap(), current_uid);
        }
    }

    #[test]
    fn zero_pid_is_rejected() {
        assert!(subject_uid(0).is_err());
    }
}
