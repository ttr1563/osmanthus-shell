#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: scripts/test-installed-truncate.sh --root ABSOLUTE_PROTECTED_ROOT --acknowledge-disposable-root" >&2
}

root=""
acknowledged=false
while (($#)); do
  case "$1" in
    --root)
      (($# >= 2)) || { usage; exit 2; }
      root="$2"
      shift 2
      ;;
    --acknowledge-disposable-root)
      acknowledged=true
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[[ -n "$root" && "$acknowledged" == true ]] || { usage; exit 2; }
[[ "$root" == /* ]] || { echo "protected root must be absolute" >&2; exit 1; }
[[ "$root" != "/" ]] || { echo "refusing to test the filesystem root" >&2; exit 1; }
[[ -d "$root" && ! -L "$root" ]] || {
  echo "protected root must be an existing non-symlink directory: $root" >&2
  exit 1
}

for command in mktemp python3 realpath stat; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 1
  }
done

canonical_root="$(realpath -e -- "$root")"
[[ "$canonical_root" == "$root" ]] || {
  echo "protected root must already be canonical: $root (resolved: $canonical_root)" >&2
  exit 1
}
if [[ ! -w "$canonical_root" || ! -x "$canonical_root" ]]; then
  echo "protected root must be writable and searchable by the test identity: $canonical_root" >&2
  exit 1
fi

osmanthus_cli=/usr/bin/osmanthus
if [[ ! -f "$osmanthus_cli" || -L "$osmanthus_cli" || ! -x "$osmanthus_cli" ]]; then
  echo "installed Osmanthus CLI is missing or unsafe: $osmanthus_cli" >&2
  exit 1
fi
if [[ "$(stat -c '%u %a' "$osmanthus_cli")" != "0 755" ]]; then
  echo "installed Osmanthus CLI must be root-owned with mode 0755: $osmanthus_cli" >&2
  exit 1
fi
policy_output="$($osmanthus_cli policy list)"
python3 - "$canonical_root" "$policy_output" <<'PY'
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
lines = sys.argv[2].splitlines()
if not lines or lines[0] != "Policy source: system":
    raise SystemExit("installed acceptance requires the root-owned system policy")

covering_actions = set()
for line in lines:
    fields = line.split("\t")
    if len(fields) != 3 or fields[0] != "protected-root":
        continue
    protected = pathlib.Path(fields[1])
    if protected == target or protected in target.parents:
        covering_actions.update(action for action in fields[2].split(",") if action)

if "Truncate" not in covering_actions:
    raise SystemExit(f"target is not covered by truncate protection: {target}")
unexpected = covering_actions - {"Truncate"}
if unexpected:
    actions = ",".join(sorted(unexpected))
    raise SystemExit(
        f"target is covered by non-truncate actions ({actions}); use a dedicated truncate-only root"
    )
PY

temporary="$(mktemp -d "$root/.osmanthus-truncate-e2e.XXXXXX")"
cleanup() {
  rm -rf -- "$temporary"
}
trap cleanup EXIT

python3 - "$temporary" <<'PY'
import errno
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
kept = b"kept"


def target(name: str) -> pathlib.Path:
    path = root / name
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        if os.write(descriptor, kept) != len(kept):
            raise SystemExit(f"short fixture write: {path}")
    finally:
        os.close(descriptor)
    return path


def expect_eperm(label: str, path: pathlib.Path, operation) -> None:
    try:
        operation()
    except PermissionError as error:
        if error.errno != errno.EPERM:
            raise SystemExit(f"{label} failed with errno {error.errno}, not EPERM") from error
    else:
        raise SystemExit(f"{label} was not blocked: {path}")
    if path.read_bytes() != kept:
        raise SystemExit(f"blocked {label} changed the target: {path}")


path_target = target("path-truncate")
expect_eperm("truncate(2)", path_target, lambda: os.truncate(path_target, 0))

descriptor_target = target("descriptor-truncate")


def descriptor_truncate() -> None:
    descriptor = os.open(descriptor_target, os.O_WRONLY)
    try:
        os.ftruncate(descriptor, 0)
    finally:
        os.close(descriptor)


expect_eperm("ftruncate(2)", descriptor_target, descriptor_truncate)

open_target = target("open-truncate")


def open_truncate() -> None:
    descriptor = os.open(open_target, os.O_WRONLY | os.O_TRUNC)
    os.close(descriptor)


expect_eperm("O_TRUNC open", open_target, open_truncate)

write_target = target("non-truncating-write")
descriptor = os.open(write_target, os.O_WRONLY)
try:
    written = os.write(descriptor, b"pass")
finally:
    os.close(descriptor)
if written != 4 or write_target.read_bytes() != b"pass":
    raise SystemExit("truncate-only policy blocked or changed a non-truncating write")
PY

echo "Installed truncate boundary test passed: $canonical_root"
