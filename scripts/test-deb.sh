#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"
source scripts/package-version.sh
version="${1:?usage: scripts/test-deb.sh VERSION [PACKAGE_ROOT]}"
parse_osmanthus_package_version "$version"
repository_path="${2:-dist/deb}"
repository_path="$(realpath -m "$repository_path")"
case "$repository_path" in
  "$repository_root/dist"/*) ;;
  *)
    echo "package root must be below dist" >&2
    exit 1
    ;;
esac

for command in ar cmp grep tar uname; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 1
  }
done

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "the Debian package must be tested natively on Linux" >&2
  exit 1
fi
case "$(uname -m)" in
  x86_64) deb_architecture="amd64" ;;
  aarch64) deb_architecture="arm64" ;;
  *)
    echo "unsupported Debian package architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

package="$repository_path/osmanthus_${OSMANTHUS_DEB_VERSION}_${deb_architecture}.deb"
test -s "$package"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
(
  cd "$temporary"
  ar x "$package"
)
test "$(<"$temporary/debian-binary")" = "2.0"
tar -xzf "$temporary/control.tar.gz" -C "$temporary"
tar -xzf "$temporary/data.tar.gz" -C "$temporary"
grep -Fx "Package: osmanthus" "$temporary/control"
grep -Fx "Version: ${OSMANTHUS_DEB_VERSION}" "$temporary/control"
grep -Fx "Architecture: $deb_architecture" "$temporary/control"
grep -Fx "Conflicts: onyx" "$temporary/control"
grep -Fq "/sys/fs/bpf/osmanthus" "$temporary/prerm"
grep -Fq "/usr/bin/osmanthus-shell" "$temporary/prerm"
grep -Fq "systemctl disable --now osmanthusd.service" "$temporary/prerm"
fixture_bin="$temporary/fixture-bin"
mkdir -p "$fixture_bin"
printf '%s\n' \
  '#!/bin/sh' \
  'test "$1" = passwd' \
  'printf "%s\n" "${OSMANTHUS_TEST_PASSWD:-}"' \
  > "$fixture_bin/getent"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "$*" >> "$OSMANTHUS_TEST_SYSTEMCTL_LOG"' \
  'if [ "$1" = is-active ]; then exit "${OSMANTHUS_TEST_ACTIVE_STATUS:-1}"; fi' \
  'exit 0' \
  > "$fixture_bin/systemctl"
chmod 0755 "$fixture_bin/getent" "$fixture_bin/systemctl"
systemctl_log="$temporary/systemctl.log"
: > "$systemctl_log"

legacy_passwd='legacy:x:1001:1001::/home/legacy:/usr/bin/onyx-shell'
if PATH="$fixture_bin:$PATH" OSMANTHUS_TEST_PASSWD="$legacy_passwd" \
  "$temporary/preinst" install >/dev/null 2>&1; then
  echo "Debian preinst accepted a legacy Onyx login shell on initial install" >&2
  exit 1
fi
PATH="$fixture_bin:$PATH" OSMANTHUS_TEST_PASSWD="$legacy_passwd" \
  "$temporary/preinst" upgrade 0.1.2

monitored_passwd='operator:x:1002:1002::/home/operator:/usr/bin/osmanthus-shell'
if PATH="$fixture_bin:$PATH" OSMANTHUS_TEST_PASSWD="$monitored_passwd" \
  OSMANTHUS_TEST_SYSTEMCTL_LOG="$systemctl_log" \
  "$temporary/prerm" remove >/dev/null 2>&1; then
  echo "Debian prerm accepted a monitored login shell on removal" >&2
  exit 1
fi
PATH="$fixture_bin:$PATH" OSMANTHUS_TEST_PASSWD="$monitored_passwd" \
  OSMANTHUS_TEST_SYSTEMCTL_LOG="$systemctl_log" \
  "$temporary/prerm" upgrade 0.1.2
test ! -s "$systemctl_log"
PATH="$fixture_bin:$PATH" OSMANTHUS_TEST_PASSWD='' \
  OSMANTHUS_TEST_SYSTEMCTL_LOG="$systemctl_log" \
  "$temporary/prerm" remove
if [[ -d /run/systemd/system ]]; then
  grep -Fqx 'disable --now osmanthusd.service' "$systemctl_log"
else
  test ! -s "$systemctl_log"
fi

: > "$systemctl_log"
PATH="$fixture_bin:$PATH" OSMANTHUS_TEST_SYSTEMCTL_LOG="$systemctl_log" \
  OSMANTHUS_TEST_ACTIVE_STATUS=1 "$temporary/postinst" configure
grep -Fqx 'daemon-reload' "$systemctl_log"
grep -Fqx 'is-active --quiet osmanthusd.service' "$systemctl_log"
! grep -Fqx 'try-restart osmanthusd.service' "$systemctl_log"

: > "$systemctl_log"
PATH="$fixture_bin:$PATH" OSMANTHUS_TEST_SYSTEMCTL_LOG="$systemctl_log" \
  OSMANTHUS_TEST_ACTIVE_STATUS=0 "$temporary/postinst" configure
grep -Fqx 'daemon-reload' "$systemctl_log"
grep -Fqx 'is-active --quiet osmanthusd.service' "$systemctl_log"
grep -Fqx 'try-restart osmanthusd.service' "$systemctl_log"

: > "$systemctl_log"
PATH="$fixture_bin:$PATH" OSMANTHUS_TEST_SYSTEMCTL_LOG="$systemctl_log" \
  "$temporary/postrm" remove
test "$(grep -Fxc 'daemon-reload' "$systemctl_log")" -eq 1
test -x "$temporary/usr/bin/osmanthus"
test -x "$temporary/usr/bin/osmanthusd"
test -x "$temporary/usr/bin/osmanthus-shell"
test -s "$temporary/lib/systemd/system/osmanthusd.service"
! grep -Fqx "PrivateTmp=yes" "$temporary/lib/systemd/system/osmanthusd.service"
grep -Fqx "ReadWritePaths=/run/osmanthus /var/log/osmanthus /sys/fs/bpf /etc/osmanthus/admin" \
  "$temporary/lib/systemd/system/osmanthusd.service"
! grep -Eq '^ReadWritePaths=(/etc/osmanthus([[:space:]]|$)|.*[[:space:]]/etc/osmanthus([[:space:]]|$))' \
  "$temporary/lib/systemd/system/osmanthusd.service"
test -s "$temporary/etc/logrotate.d/osmanthus"
grep -Fqx "/var/lib/osmanthus/audit.jsonl {" "$temporary/etc/logrotate.d/osmanthus"
grep -Fqx "/var/log/osmanthus/audit.jsonl {" "$temporary/etc/logrotate.d/osmanthus"
grep -Fqx "/etc/osmanthus/admin/audit.jsonl {" "$temporary/etc/logrotate.d/osmanthus"
test "$(grep -Fc "    create 0600 root root" "$temporary/etc/logrotate.d/osmanthus")" -eq 3
test -s "$temporary/usr/share/doc/osmanthus/ssm.md.gz"
gzip -cd "$temporary/usr/share/doc/osmanthus/README.md.gz" | grep -Fq "caller cgroup"
gzip -cd "$temporary/usr/share/doc/osmanthus/operations.md.gz" | grep -Fq "dedicated transient systemd service"
test -s "$temporary/usr/share/osmanthus/ssm/osmanthus-session.json"
cmp -s ops/ssm/osmanthus-session.json \
  "$temporary/usr/share/osmanthus/ssm/osmanthus-session.json"
"$temporary/usr/bin/osmanthus" --version | grep -Fx "osmanthus $version"
"$temporary/usr/bin/osmanthus" daemon --help | grep -F decommission
"$temporary/usr/bin/osmanthus" maintenance --help | grep -F grant
"$temporary/usr/bin/osmanthus" maintenance --help | grep -F pause
"$temporary/usr/bin/osmanthus" policy maintenance set --help | grep -F -- --maximum
"$temporary/usr/bin/osmanthus" policy protect add --help | grep -F write
"$temporary/usr/bin/osmanthus" policy auth --help | grep -F rotate
set +e
"$temporary/usr/bin/osmanthus" check -- rm -rf /example >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -ne 77 ]]; then
  echo "blocked command check returned unexpected status: $status" >&2
  exit 1
fi
