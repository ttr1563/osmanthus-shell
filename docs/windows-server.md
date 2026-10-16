# Windows Server native enforcement track

> Status: design contract only. No Windows service, driver, installer, or native
> integration test exists in this repository. WSL does not satisfy this track.

This track is intentionally separate from the first Linux release. Linux can be
accepted when its own packaged gates pass; none of those results advertise or
imply Windows Server support. Windows support begins only after every acceptance
gate in this document passes on a supported native Windows Server host.

## Security contract

The Windows implementation must preserve the same product invariants as Linux:

- normal PowerShell, `cmd.exe`, WinRM, RDP-launched terminals, Scheduled Tasks,
  and enrolled services do not require an `osmanthus run` prefix;
- protected filesystem operations are rejected before their targets change,
  independently of executable names and shell syntax;
- a privileged service owns policy, the TOTP verifier, maintenance state, and
  local audit evidence;
- maintenance is limited to selected roots, operation classes, one authenticated
  session boundary, and a bounded lifetime; it is never a driver unload or
  service-wide disable switch;
- loss of the user-mode service does not silently detach an already active
  protected-root boundary;
- Windows Administrator/SYSTEM, a compromised kernel, and a compromised boot
  chain remain outside the containment claim.

User-mode command interception, PowerShell profiles, AppLocker rules, or WSL
alone cannot satisfy the synchronous protected-resource boundary.

## Separated architecture

| Responsibility | Native Windows component | Shared contract |
| --- | --- | --- |
| Filesystem decision | Signed file-system minifilter driver | Protected root, operation class, decision, event identity |
| Policy and approval | Privileged Windows Service | Versioned policy, TOTP, lockout, maintenance, audit schemas |
| Interactive transcript | Entry-point adapters using a supervised console/PTY path | Session start, input/output, process, and end records |
| Administration | Native CLI communicating with the service over a restricted local IPC endpoint | Authenticated mutations and explicit rollback |
| Installation | Windows installer plus separately signed driver package | Immutable version and upgrade/rollback contract |

The minifilter is the enforcement boundary. It must register pre-operation
callbacks for every filesystem path needed to cover deletion, rename or move,
truncate or overwrite, opt-in ordinary writes, and ownership or ACL changes.
The exact IRP and file-information-class matrix must be established from a
prototype and regression tests; it must not be inferred from command names.

The service and driver communicate through a versioned protocol and a device
object whose ACL permits only the service identity and explicitly authorized
administrators. Policy replacement must be atomic from the driver's point of
view. A service crash may prevent new approvals and transcript capture, but it
must not convert a protected operation into an allowed operation.

## Session and maintenance identity

Windows has no Linux cgroup equivalent. The first prototype must compare both:

1. binding a lease to the caller's LSA logon-session identifier (LUID); and
2. launching supervised descendants in a non-breakaway Job Object and binding
   the lease to that job.

An LSA logon session supplies a kernel-issued logon identifier, while a Job
Object can group descendants. Job breakaway settings and pre-existing processes
make neither choice automatically equivalent to the Linux cgroup contract.
The selected identity must demonstrate all of the following before it becomes
part of the shared policy schema:

- descendants that should share a lease do share it;
- a different RDP, WinRM, local, service, or scheduled-task session remains
  denied even when it uses the same account;
- a process cannot obtain the lease by changing executable names, spawning a
  helper, duplicating a token, or escaping a job;
- expiry, explicit revocation, logoff, and service restart remove the lease;
- the driver can evaluate the identity without trusting caller-supplied data.

Until one design passes these tests, Windows maintenance scoping is **unresolved**,
not implemented with a weaker account-wide fallback.

## State, secrets, and evidence

The intended storage root is a service-owned directory below
`%ProgramData%\Osmanthus`. ACLs must deny modification by managed non-admin
identities. Policy and audit formats may share versioned schemas with Linux, but
paths, ownership metadata, session identifiers, and kernel event fields require
Windows-specific adapters.

The TOTP seed must be protected for the service identity with a Windows-native
secret-protection mechanism and restrictive ACLs. The design must include
rotation, replay prevention, lockout, authenticated backup, and a separately
approved lost-authenticator recovery contract. Encrypting the seed does not
protect it after Administrator/SYSTEM compromise.

Local JSONL remains the default evidence destination. Windows Event Log or
remote forwarding may be added independently; neither replaces the privileged
local record. Transcript capture must disclose that raw terminal data can
contain secrets.

## Repository and release separation

The future implementation should remain in explicit platform directories, for
example:

```text
windows/driver/          # minifilter and driver/service protocol
windows/service/         # policy, TOTP, leases, audit, driver lifecycle
windows/session/         # PowerShell, cmd, WinRM, RDP terminal adapters
packaging/windows/       # installer and signed driver-package definitions
tests/windows-e2e/       # native Windows Server acceptance tests
```

Linux `libbpf`, systemd, Unix-socket, cgroup, login-shell, deb, and RPM code must
not acquire untested Windows fallbacks. Shared schemas must be factored only
after compatibility tests prove that their semantics match. Windows artifacts,
signing identities, release notes, support matrix, and rollback evidence are
published independently from Linux packages.

## Native test environments

Initial implementation and acceptance require disposable x64 virtual machines
for each advertised Windows Server release. At minimum, test the oldest and
newest advertised releases with:

- Secure Boot and production driver-signing policy enabled;
- PowerShell, `cmd.exe`, WinRM, and an RDP-launched terminal;
- Scheduled Tasks and an enrolled Windows Service;
- NTFS local volumes plus every other filesystem type explicitly advertised;
- snapshot or image rollback independent of the Osmanthus installer.

Test-signed driver development is isolated from release-signed acceptance. A
test-signing result must never be reported as installability on a normal
Secure-Boot production host. External VM, signing, certification, and hosted CI
costs require their own approval; the Linux release does not create those
resources automatically.

## Acceptance gates

Windows Server support remains unavailable until all of these pass from signed
installer artifacts:

1. Install and boot-start of the service and minifilter under normal production
   driver-signing policy.
2. Synchronous denial, with unchanged targets, for delete, rename/move,
   truncate/overwrite, opt-in write, and owner/ACL changes through native APIs,
   PowerShell, `cmd.exe`, and alternate executables.
3. Allowed harmless work and destructive work outside protected roots.
4. No bypass through hard links, reparse points, alternate data streams, case or
   path normalization, volume aliases, network shares claimed as supported, or
   already-open handles.
5. Correct behavior across PowerShell, cmd, WinRM, RDP terminals, Scheduled
   Tasks, and enrolled services without a voluntary wrapper prefix.
6. Session transcript and process evidence for every advertised interactive
   entry point, with fail-closed interactive behavior when required audit cannot
   be recorded.
7. TOTP maintenance restricted to the selected roots, operations, session
   identity, and lifetime; another concurrent session remains denied.
8. Protected-root enforcement remains active during a service crash, audit
   failure, and failed upgrade; recovery does not delete driver state by hand.
9. Policy/secret/audit ACL tampering by a managed non-admin identity is denied
   and audited.
10. Install, enable, disable, upgrade, rollback, decommission, and uninstall
    preserve policy and audit evidence and restore every modified entry point.
11. Driver and installer signatures, checksums, rollback artifacts, support
    matrix, and incident runbook are published from immutable release inputs.

## Microsoft platform references

- [Registering minifilter pre/post-operation callbacks](https://learn.microsoft.com/en-us/windows-hardware/drivers/ifs/registering-preoperation-and-postoperation-callback-routines)
- [File-system minifilter operation guidance](https://learn.microsoft.com/en-us/windows-hardware/drivers/ifs/filtering-i-o-operations-in-a-minifilter-driver)
- [Windows kernel-mode driver signing](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/windows-driver-signing-tutorial)
- [LSA logon sessions](https://learn.microsoft.com/en-us/windows/win32/secauthn/lsa-logon-sessions)
- [Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)
