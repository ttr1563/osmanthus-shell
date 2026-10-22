#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"
source scripts/package-version.sh
source scripts/signing-identity.sh
source scripts/repository-publish.sh
output_root="${1:-docs/rpm}"
output_root="$(realpath -m "$output_root")"
case "$output_root" in
  "$repository_root/docs/rpm" | "$repository_root/dist"/*) ;;
  *)
    echo "output root must be docs/rpm or a path below dist" >&2
    exit 1
    ;;
esac

key_file="${OSMANTHUS_GPG_PUBLIC_KEY:-packaging/rpm/RPM-GPG-KEY-OSMANTHUS}"
signing_key="${OSMANTHUS_GPG_KEY_ID:-}"
gpg_home="${OSMANTHUS_GPG_HOME:-}"
passphrase_file="${OSMANTHUS_GPG_PASSPHRASE_FILE:-}"
for command in cp createrepo_c find gpg install mktemp python3 realpath rpm rpmbuild sha256sum sort; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 1
  }
done
if [[ ! -s "$key_file" ]]; then
  echo "Osmanthus public signing key not found: $key_file" >&2
  exit 1
fi
if [[ -z "$signing_key" || -z "$gpg_home" ]]; then
  echo "OSMANTHUS_GPG_KEY_ID and OSMANTHUS_GPG_HOME are required" >&2
  exit 1
fi
require_osmanthus_signing_identity "$key_file" "$gpg_home" "$signing_key"

mapfile -t package_directories < <(find "$output_root/al2023" -mindepth 2 -maxdepth 2 \
  -type d -name Packages -print 2>/dev/null | sort)
if [[ "${#package_directories[@]}" -eq 0 ]]; then
  echo "Osmanthus RPM package directories not found under $output_root/al2023" >&2
  exit 1
fi
for package_directory in "${package_directories[@]}"; do
  architecture="$(basename "$(dirname "$package_directory")")"
  case "$architecture" in
    x86_64 | aarch64) ;;
    *) echo "unsupported RPM repository architecture: $architecture" >&2; exit 1 ;;
  esac
  if ! find "$package_directory" -maxdepth 1 -type f \
    -name "osmanthus-*.${architecture}.rpm" -print -quit | grep -q .; then
    echo "Osmanthus $architecture package not found under $package_directory" >&2
    exit 1
  fi
  for package in "$package_directory"/osmanthus-*.rpm; do
    if [[ "$(rpm --query --package "$package" --queryformat '%{NAME} %{ARCH}')" != "osmanthus $architecture" ]]; then
      echo "unexpected RPM package identity: $package" >&2
      exit 1
    fi
  done
done

temporary="$(mktemp -d)"
repository_stage=""
cleanup() {
  rm -rf "$temporary"
  if [[ -n "$repository_stage" && ( -e "$repository_stage" || -L "$repository_stage" ) ]]; then
    discard_osmanthus_repository_stage "$output_root" "$repository_stage"
  fi
}
trap cleanup EXIT
prepare_osmanthus_repository_stage "$output_root"
repository_stage="$OSMANTHUS_REPOSITORY_STAGE"
mapfile -t package_directories < <(find "$repository_stage/al2023" -mindepth 2 -maxdepth 2 \
  -type d -name Packages -print | sort)
bootstrap_output="$repository_stage/osmanthus-release-1-1.noarch.rpm"
new_bootstrap=0
if [[ -e "$bootstrap_output" || -L "$bootstrap_output" ]]; then
  if [[ ! -f "$bootstrap_output" || -L "$bootstrap_output" ]]; then
    echo "existing Osmanthus bootstrap package is not a regular file" >&2
    exit 1
  fi
  bootstrap_package="$bootstrap_output"
else
  topdir="$temporary/rpmbuild"
  mkdir -p "$topdir"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
  install -m0644 packaging/rpm/osmanthus.repo "$topdir/SOURCES/osmanthus.repo"
  install -m0644 "$key_file" "$topdir/SOURCES/RPM-GPG-KEY-OSMANTHUS"
  install -m0644 packaging/rpm/osmanthus-release.spec "$topdir/SPECS/osmanthus-release.spec"
  rpmbuild --define "_topdir $topdir" -bb "$topdir/SPECS/osmanthus-release.spec"
  bootstrap_package="$(find "$topdir/RPMS/noarch" -maxdepth 1 -type f \
    -name 'osmanthus-release-*.noarch.rpm' -print -quit)"
  test -n "$bootstrap_package"
  new_bootstrap=1
fi

signing_arguments=(
  --define "_gpg_name $signing_key"
  --define "_gpg_path $gpg_home"
)
gpg_arguments=(--batch --yes --local-user "$signing_key")
verification_db="$temporary/rpmdb"
mkdir -p "$verification_db"
rpm --dbpath "$verification_db" --initdb
rpm --dbpath "$verification_db" --import "$key_file"
if [[ -n "$passphrase_file" ]]; then
  if [[ ! -r "$passphrase_file" ]]; then
    echo "GPG passphrase file is not readable" >&2
    exit 1
  fi
  signing_arguments+=(
    --define "_gpg_sign_cmd_extra_args --batch --pinentry-mode loopback --passphrase-file $passphrase_file"
  )
  gpg_arguments+=(--pinentry-mode loopback --passphrase-file "$passphrase_file")
fi

ensure_package_signed() {
  local package="${1:?RPM package is required}"
  local signatures

  signatures="$(rpm --query --package "$package" \
    --queryformat '%{RSAHEADER}%{DSAHEADER}%{SIGPGP}%{SIGGPG}' 2>/dev/null)"
  if [[ "$signatures" = '(none)(none)(none)(none)' ]]; then
    GNUPGHOME="$gpg_home" rpmsign "${signing_arguments[@]}" --addsign "$package"
  fi
  if ! rpm --dbpath "$verification_db" --checksig "$package"; then
    echo "existing RPM signature is not valid for the configured Osmanthus key: $package" >&2
    return 1
  fi
}

for package_directory in "${package_directories[@]}"; do
  for package in "$package_directory"/osmanthus-*.rpm; do
    ensure_package_signed "$package"
  done
done
ensure_package_signed "$bootstrap_package"
if [[ "$new_bootstrap" -eq 1 ]]; then
  require_new_osmanthus_artifact "$bootstrap_output"
  install -m0644 "$bootstrap_package" "$bootstrap_output"
  bootstrap_package="$bootstrap_output"
fi

for package_directory in "${package_directories[@]}"; do
  architecture="$(basename "$(dirname "$package_directory")")"
  metadata_root="$temporary/repository-$architecture"
  mkdir -p "$metadata_root/Packages"
  cp -p "$package_directory"/osmanthus-*.rpm "$metadata_root/Packages/"
  createrepo_c --checksum sha256 --workers 1 "$metadata_root"
  GNUPGHOME="$gpg_home" gpg "${gpg_arguments[@]}" \
    --armor --detach-sign "$metadata_root/repodata/repomd.xml"
  rm -rf "$repository_stage/al2023/$architecture/repodata"
  cp -a "$metadata_root/repodata" "$repository_stage/al2023/$architecture/repodata"
done

install -m0644 "$key_file" "$repository_stage/RPM-GPG-KEY-OSMANTHUS"
(
  cd "$repository_stage"
  {
    printf '%s\n' RPM-GPG-KEY-OSMANTHUS osmanthus-release-1-1.noarch.rpm
    find al2023 -type f \( -name '*.rpm' -o -name 'repomd.xml' \) -print | sort
  } | xargs sha256sum > SHA256SUMS
)
GNUPGHOME="$gpg_home" gpg "${gpg_arguments[@]}" \
  --armor --detach-sign "$repository_stage/SHA256SUMS"

publish_osmanthus_repository_stage "$output_root" "$repository_stage"
repository_stage=""
mapfile -t signed_packages < <(find "$output_root/al2023" -type f -name 'osmanthus-*.rpm' -print | sort)
sha256sum "$output_root/osmanthus-release-1-1.noarch.rpm" "${signed_packages[@]}"
