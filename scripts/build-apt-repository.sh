#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"
source scripts/signing-identity.sh
source scripts/repository-publish.sh
output_root="${1:-docs/apt}"
output_root="$(realpath -m "$output_root")"
case "$output_root" in
  "$repository_root/docs/apt" | "$repository_root/dist"/*) ;;
  *)
    echo "output root must be docs/apt or a path below dist" >&2
    exit 1
    ;;
esac

key_file="${OSMANTHUS_GPG_PUBLIC_KEY:-packaging/rpm/RPM-GPG-KEY-OSMANTHUS}"
signing_key="${OSMANTHUS_GPG_KEY_ID:-}"
gpg_home="${OSMANTHUS_GPG_HOME:-}"
passphrase_file="${OSMANTHUS_GPG_PASSPHRASE_FILE:-}"
for command in ar awk cp date find gpg gzip install md5sum mktemp python3 realpath sha256sum sort stat tar xargs; do
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

pool="$output_root/pool/main/o/osmanthus"
mapfile -t packages < <(find "$pool" -maxdepth 1 -type f -name 'osmanthus_*.deb' -print | sort -V)
if [[ "${#packages[@]}" -eq 0 ]]; then
  echo "Osmanthus Debian package not found under $pool" >&2
  exit 1
fi

temporary="$(mktemp -d)"
repository_stage=""
cleanup() {
  rm -rf "$temporary"
  if [[ -n "$repository_stage" && ( -e "$repository_stage" || -L "$repository_stage" ) ]]; then
    discard_osmanthus_repository_stage "$output_root" "$repository_stage"
  fi
}
trap cleanup EXIT
metadata_root="$temporary/apt"
declare -A architecture_seen=()
for index in "${!packages[@]}"; do
  package="${packages[$index]}"
  control_dir="$temporary/control-$index"
  mkdir -p "$control_dir"
  (
    cd "$control_dir"
    ar x "$package" control.tar.gz
    tar -xzf control.tar.gz control
  )
  if ! grep -Fqx 'Package: osmanthus' "$control_dir/control"; then
    echo "unexpected Debian package identity: $package" >&2
    exit 1
  fi
  package_version="$(awk '/^Version: / { print $2; exit }' "$control_dir/control")"
  architecture="$(awk '/^Architecture: / { print $2; exit }' "$control_dir/control")"
  case "$architecture" in
    amd64 | arm64) ;;
    *)
      echo "unsupported Debian repository architecture in $package: $architecture" >&2
      exit 1
      ;;
  esac
  expected_package="$pool/osmanthus_${package_version}_${architecture}.deb"
  if [[ "$package" != "$expected_package" ]]; then
    echo "Debian package filename does not match its control metadata: $package" >&2
    exit 1
  fi
  architecture_seen["$architecture"]=1
  binary_dir="$metadata_root/dists/stable/main/binary-$architecture"
  mkdir -p "$binary_dir"
  packages_file="$binary_dir/Packages"
  if [[ -s "$packages_file" ]]; then
    printf '\n' >> "$packages_file"
  fi
  relative_package="${package#"$output_root"/}"
  cat "$control_dir/control" >> "$packages_file"
  cat >> "$packages_file" <<EOF
Filename: ${relative_package}
Size: $(stat -c %s "$package")
MD5sum: $(md5sum "$package" | awk '{ print $1 }')
SHA256: $(sha256sum "$package" | awk '{ print $1 }')
EOF
done

mapfile -t architectures < <(printf '%s\n' "${!architecture_seen[@]}" | sort)
for architecture in "${architectures[@]}"; do
  binary_dir="$metadata_root/dists/stable/main/binary-$architecture"
  gzip -9 -n -c "$binary_dir/Packages" > "$binary_dir/Packages.gz"
done

release="$metadata_root/dists/stable/Release"
release_epoch="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}"
{
  echo "Origin: Osmanthus"
  echo "Label: Osmanthus"
  echo "Suite: stable"
  echo "Codename: stable"
  echo "Version: 1"
  echo "Architectures: ${architectures[*]}"
  echo "Components: main"
  echo "Description: Osmanthus packages for Debian and Ubuntu"
  echo "Date: $(date --utc --date="@${release_epoch}" --rfc-email)"
  echo "SHA256:"
  for architecture in "${architectures[@]}"; do
    for name in Packages Packages.gz; do
      file="main/binary-$architecture/$name"
      printf ' %s %16s %s\n' \
        "$(sha256sum "$metadata_root/dists/stable/$file" | awk '{ print $1 }')" \
        "$(stat -c %s "$metadata_root/dists/stable/$file")" \
        "$file"
    done
  done
} > "$release"

gpg_arguments=(--batch --yes --local-user "$signing_key" --digest-algo SHA256)
if [[ -n "$passphrase_file" ]]; then
  if [[ ! -r "$passphrase_file" ]]; then
    echo "GPG passphrase file is not readable" >&2
    exit 1
  fi
  gpg_arguments+=(--pinentry-mode loopback --passphrase-file "$passphrase_file")
fi
GNUPGHOME="$gpg_home" gpg "${gpg_arguments[@]}" \
  --clearsign --output "$metadata_root/dists/stable/InRelease" "$release"
GNUPGHOME="$gpg_home" gpg "${gpg_arguments[@]}" \
  --armor --detach-sign --output "$metadata_root/dists/stable/Release.gpg" "$release"

prepare_osmanthus_repository_stage "$output_root"
repository_stage="$OSMANTHUS_REPOSITORY_STAGE"
rm -rf "$repository_stage/dists"
cp -a "$metadata_root/dists" "$repository_stage/dists"
install -m0644 "$key_file" "$repository_stage/osmanthus.asc"
install -m0644 packaging/deb/osmanthus.sources "$repository_stage/osmanthus.sources"

(
  cd "$repository_stage"
  {
    printf '%s\n' osmanthus.asc osmanthus.sources
    find dists pool -type f -print | sort
  } | xargs sha256sum > SHA256SUMS
)
GNUPGHOME="$gpg_home" gpg "${gpg_arguments[@]}" \
  --armor --detach-sign --output "$repository_stage/SHA256SUMS.asc" "$repository_stage/SHA256SUMS"

publish_osmanthus_repository_stage "$output_root" "$repository_stage"
repository_stage=""

sha256sum "${packages[@]}" "$output_root/dists/stable/InRelease"
