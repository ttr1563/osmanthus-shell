#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"
apt_root="$(realpath -m "${1:?usage: scripts/test-signed-repositories.sh APT_ROOT RPM_ROOT}")"
rpm_root="$(realpath -m "${2:?usage: scripts/test-signed-repositories.sh APT_ROOT RPM_ROOT}")"
case "$apt_root" in
  "$repository_root/dist"/*) ;;
  *) echo "APT test root must be below dist" >&2; exit 1 ;;
esac
case "$rpm_root" in
  "$repository_root/dist"/*) ;;
  *) echo "RPM test root must be below dist" >&2; exit 1 ;;
esac

for command in awk find gpg gpgconf grep mkdir realpath rpm; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 1
  }
done
find "$apt_root/pool/main/o/osmanthus" -maxdepth 1 -type f \
  -name 'osmanthus_*.deb' -print -quit | grep -q .
find "$rpm_root/al2023" -type f -name 'osmanthus-*.rpm' -print -quit | grep -q .

temporary="$(mktemp -d)"
gpg_home="$temporary/gnupg"
public_key="$temporary/RPM-GPG-KEY-OSMANTHUS"
cleanup() {
  GNUPGHOME="$gpg_home" gpgconf --kill gpg-agent >/dev/null 2>&1 || true
  rm -rf "$temporary"
}
trap cleanup EXIT
mkdir -m0700 "$gpg_home"
GNUPGHOME="$gpg_home" gpg --batch --pinentry-mode loopback --passphrase '' \
  --quick-generate-key 'Osmanthus ephemeral repository test' rsa2048 sign 1d
fingerprint="$(GNUPGHOME="$gpg_home" gpg --batch --with-colons --list-secret-keys \
  | awk -F: '$1 == "fpr" { print $10; exit }')"
test -n "$fingerprint"
GNUPGHOME="$gpg_home" gpg --batch --armor --export "$fingerprint" > "$public_key"
test -s "$public_key"

export OSMANTHUS_GPG_HOME="$gpg_home"
export OSMANTHUS_GPG_KEY_ID="$fingerprint"
export OSMANTHUS_GPG_PUBLIC_KEY="$public_key"
scripts/build-apt-repository.sh "$apt_root"
scripts/verify-apt-repository.sh "$apt_root"
scripts/build-rpm-repository.sh "$rpm_root"
(
  cd "$rpm_root"
  {
    printf '%s\n' osmanthus-release-1-1.noarch.rpm
    find al2023 -type f -name 'osmanthus-*.rpm' -print | sort
  } | xargs sha256sum > "$temporary/rpm-package-checksums"
)
GNUPGHOME="$gpg_home" gpg --batch --pinentry-mode loopback --passphrase '' \
  --quick-generate-key 'Osmanthus wrong repository test key' rsa2048 sign 1d
wrong_fingerprint="$(GNUPGHOME="$gpg_home" gpg --batch --with-colons \
  --list-secret-keys 'Osmanthus wrong repository test key' \
  | awk -F: '$1 == "fpr" { print $10; exit }')"
wrong_public_key="$temporary/RPM-GPG-KEY-WRONG"
test -n "$wrong_fingerprint"
GNUPGHOME="$gpg_home" gpg --batch --armor --export "$wrong_fingerprint" > "$wrong_public_key"
if OSMANTHUS_GPG_KEY_ID="$wrong_fingerprint" \
  OSMANTHUS_GPG_PUBLIC_KEY="$wrong_public_key" \
  scripts/build-rpm-repository.sh "$rpm_root" \
  >"$temporary/wrong-key-output" 2>&1; then
  echo 'existing RPMs were accepted with a different signing key' >&2
  exit 1
fi
grep -F 'existing RPM signature is not valid for the configured Osmanthus key' \
  "$temporary/wrong-key-output" >/dev/null
(
  cd "$rpm_root"
  sha256sum --check "$temporary/rpm-package-checksums"
)
scripts/build-rpm-repository.sh "$rpm_root"
(
  cd "$rpm_root"
  sha256sum --check "$temporary/rpm-package-checksums"
)
scripts/verify-rpm-repository.sh \
  "$rpm_root/al2023/$(rpm --eval '%{_target_cpu}')" \
  "$rpm_root/RPM-GPG-KEY-OSMANTHUS"

echo 'Ephemeral signed APT and RPM repositories verified.'
