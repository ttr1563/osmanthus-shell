#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"
source scripts/package-version.sh

version="${1:?usage: scripts/test-rpm.sh VERSION [PACKAGE_ROOT]}"
parse_osmanthus_package_version "$version"
for command in find grep realpath rpm uname; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 1
  }
done
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "RPM packages must be tested natively on Linux" >&2
  exit 1
fi
host_architecture="$(uname -m)"
architecture="$(rpm --eval '%{_target_cpu}')"
require_native_osmanthus_rpm_architecture "$host_architecture" "$architecture"
repository_path="${2:-dist/rpm/$architecture}"
repository_path="$(realpath -m "$repository_path")"
case "$repository_path" in
  "$repository_root/dist"/*) ;;
  *)
    echo "package root must be below dist" >&2
    exit 1
    ;;
esac
package="$(find "$repository_path/Packages" -maxdepth 1 -type f -name "osmanthus-${OSMANTHUS_RPM_VERSION}-${OSMANTHUS_RPM_RELEASE}*.rpm" -print -quit)"

if [[ -z "$package" ]]; then
  echo "Osmanthus RPM is missing" >&2
  exit 1
fi
if [[ "$(rpm -qp --qf '%{ARCH}' "$package")" != "$architecture" ]]; then
  echo "RPM package architecture does not match native host: $package" >&2
  exit 1
fi

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
rpm -qp --requires "$package" > "$temporary/requires"
grep -Fxq 'shadow-utils' "$temporary/requires"
grep -Fxq 'polkit' "$temporary/requires"
grep -Fxq 'systemd' "$temporary/requires"
install_root="$temporary/root"
mkdir -p "$install_root/var/lib/rpm"
rpm --root "$install_root" --dbpath /var/lib/rpm --initdb
rpm --checksig "$package"
rpm --query --package "$package" --scripts > "$temporary/scriptlets"
grep -Fq 'if [ "$1" -eq 1 ]; then' "$temporary/scriptlets"
grep -Fq 'legacy Onyx BPF pins remain' "$temporary/scriptlets"
grep -Fq 'if [ "$1" -eq 0 ]; then' "$temporary/scriptlets"
grep -Fq "run 'sudo osmanthus daemon decommission' before uninstall" "$temporary/scriptlets"
grep -Fq 'restore monitored login shells before uninstall' "$temporary/scriptlets"
grep -Fq 'Package removal, not upgrade' "$temporary/scriptlets"
grep -Fq 'Package upgrade, not uninstall' "$temporary/scriptlets"
rpm --root "$install_root" --dbpath /var/lib/rpm --nodeps --noscripts -i "$package"

test -x "$install_root/usr/bin/osmanthus"
test -x "$install_root/usr/bin/osmanthusd"
test -x "$install_root/usr/bin/osmanthus-shell"
test -x "$install_root/usr/libexec/osmanthus-polkit"
test -s "$install_root/usr/share/polkit-1/rules.d/00-osmanthus.rules"
grep -Fq 'org.freedesktop.systemd1.manage-units' \
  "$install_root/usr/share/polkit-1/rules.d/00-osmanthus.rules"
grep -Fq '/usr/libexec/osmanthus-polkit' \
  "$install_root/usr/share/polkit-1/rules.d/00-osmanthus.rules"
test -s "$install_root/usr/lib/systemd/system/osmanthusd.service"
! grep -Fqx "PrivateTmp=yes" "$install_root/usr/lib/systemd/system/osmanthusd.service"
grep -Fqx "ReadWritePaths=/run/osmanthus /var/log/osmanthus /sys/fs/bpf /etc/osmanthus/admin" \
  "$install_root/usr/lib/systemd/system/osmanthusd.service"
! grep -Eq '^ReadWritePaths=(/etc/osmanthus([[:space:]]|$)|.*[[:space:]]/etc/osmanthus([[:space:]]|$))' \
  "$install_root/usr/lib/systemd/system/osmanthusd.service"
test -s "$install_root/etc/logrotate.d/osmanthus"
grep -Fqx "/var/lib/osmanthus/audit.jsonl {" "$install_root/etc/logrotate.d/osmanthus"
grep -Fqx "/var/log/osmanthus/audit.jsonl {" "$install_root/etc/logrotate.d/osmanthus"
grep -Fqx "/etc/osmanthus/admin/audit.jsonl {" "$install_root/etc/logrotate.d/osmanthus"
test "$(grep -Fc "    create 0600 root root" "$install_root/etc/logrotate.d/osmanthus")" -eq 3
test -s "$install_root/usr/share/doc/osmanthus/ssm.md"
grep -Fq "caller cgroup" "$install_root/usr/share/doc/osmanthus/README.md"
grep -Fq "dedicated transient systemd service" "$install_root/usr/share/doc/osmanthus/operations.md"
test -s "$install_root/usr/share/osmanthus/ssm/osmanthus-session.json"
cmp -s ops/ssm/osmanthus-session.json \
  "$install_root/usr/share/osmanthus/ssm/osmanthus-session.json"
"$install_root/usr/bin/osmanthus" --version | grep -Fx "osmanthus $version"
"$install_root/usr/bin/osmanthus" daemon --help | grep -F "decommission"
"$install_root/usr/bin/osmanthus" maintenance --help | grep -F "grant"
"$install_root/usr/bin/osmanthus" maintenance --help | grep -F "pause"
"$install_root/usr/bin/osmanthus" policy maintenance set --help | grep -F -- "--maximum"
"$install_root/usr/bin/osmanthus" policy protect add --help | grep -F "write"
"$install_root/usr/bin/osmanthus" policy auth --help | grep -F "rotate"
"$install_root/usr/bin/osmanthus" policy service add --help | grep -F -- "--action"
"$install_root/usr/bin/osmanthus" service --help | grep -F "restart"
"$install_root/usr/bin/osmanthus" check -- rm -rf /example >/dev/null 2>&1 && exit 1 || status=$?
if [[ "$status" -ne 77 ]]; then
  echo "blocked command check returned unexpected status: $status" >&2
  exit 1
fi

mkdir -p "$install_root/var/lib/osmanthus"
touch "$install_root/var/lib/osmanthus/retention-marker"
mkdir -p "$install_root/etc/osmanthus"
touch "$install_root/etc/osmanthus/retention-marker"
rpm --root "$install_root" --dbpath /var/lib/rpm --nodeps --noscripts -e osmanthus
test -e "$install_root/var/lib/osmanthus/retention-marker"
test -e "$install_root/etc/osmanthus/retention-marker"
test ! -e "$install_root/usr/bin/osmanthus"
test ! -e "$install_root/usr/bin/osmanthusd"
test ! -e "$install_root/usr/bin/osmanthus-shell"
test ! -e "$install_root/usr/libexec/osmanthus-polkit"
test ! -e "$install_root/usr/share/polkit-1/rules.d/00-osmanthus.rules"
test ! -e "$install_root/usr/share/osmanthus/ssm/osmanthus-session.json"
