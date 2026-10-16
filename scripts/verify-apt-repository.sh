#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"
repository_path="${1:-docs/apt}"
repository_path="$(realpath -m "$repository_path")"
case "$repository_path" in
  "$repository_root/docs/apt" | "$repository_root/dist"/*) ;;
  *)
    echo "repository path must be docs/apt or a path below dist" >&2
    exit 1
    ;;
esac

for command in ar awk cmp find gpg grep gzip realpath sha256sum sort stat tar uname; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 1
  }
done
test -s "$repository_path/osmanthus.asc"
test -s "$repository_path/osmanthus.sources"
test -s "$repository_path/SHA256SUMS"
test -s "$repository_path/SHA256SUMS.asc"
test -s "$repository_path/dists/stable/InRelease"
test -s "$repository_path/dists/stable/Release"
test -s "$repository_path/dists/stable/Release.gpg"
grep -Fx 'Origin: Osmanthus' "$repository_path/dists/stable/Release"
grep -Fx 'URIs: https://ttr1563.github.io/osmanthus-shell/apt' "$repository_path/osmanthus.sources"
grep -Fx 'Architectures: amd64 arm64' "$repository_path/osmanthus.sources"

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
chmod 0700 "$temporary"
GNUPGHOME="$temporary" gpg --batch --import "$repository_path/osmanthus.asc" >/dev/null 2>&1
GNUPGHOME="$temporary" gpg --batch --verify "$repository_path/dists/stable/InRelease"
GNUPGHOME="$temporary" gpg --batch --decrypt \
  "$repository_path/dists/stable/InRelease" 2>/dev/null \
  | cmp - "$repository_path/dists/stable/Release"
GNUPGHOME="$temporary" gpg --batch --verify \
  "$repository_path/dists/stable/Release.gpg" \
  "$repository_path/dists/stable/Release"
GNUPGHOME="$temporary" gpg --batch --verify \
  "$repository_path/SHA256SUMS.asc" \
  "$repository_path/SHA256SUMS"
(
  cd "$repository_path"
  sha256sum --check SHA256SUMS
)

mapfile -t binary_directories < <(find "$repository_path/dists/stable/main" \
  -mindepth 1 -maxdepth 1 -type d -name 'binary-*' -print | sort)
test "${#binary_directories[@]}" -gt 0
for binary_directory in "${binary_directories[@]}"; do
  architecture="${binary_directory##*binary-}"
  case "$architecture" in
    amd64 | arm64) ;;
    *) echo "unsupported repository architecture: $architecture" >&2; exit 1 ;;
  esac
  packages_file="$binary_directory/Packages"
  test -s "$packages_file"
  test -s "$packages_file.gz"
  gzip -cd "$packages_file.gz" | cmp - "$packages_file"
  mapfile -t packages < <(find "$repository_path/pool/main/o/osmanthus" -maxdepth 1 \
    -type f -name "osmanthus_*_${architecture}.deb" -print | sort -V)
  test "${#packages[@]}" -gt 0
  test "$(grep -Fxc 'Package: osmanthus' "$packages_file")" -eq "${#packages[@]}"
  for package in "${packages[@]}"; do
    relative_package="${package#"$repository_path"/}"
    grep -Fqx "Filename: $relative_package" "$packages_file"
    grep -Fqx "Size: $(stat -c %s "$package")" "$packages_file"
    grep -Fqx "SHA256: $(sha256sum "$package" | awk '{ print $1 }')" "$packages_file"
  done
done

case "$(uname -m)" in
  x86_64) native_architecture=amd64 ;;
  aarch64) native_architecture=arm64 ;;
  *) native_architecture='' ;;
esac
if [[ -n "$native_architecture" ]]; then
  mapfile -t native_packages < <(find "$repository_path/pool/main/o/osmanthus" -maxdepth 1 \
    -type f -name "osmanthus_*_${native_architecture}.deb" -print | sort -V)
  if [[ "${#native_packages[@]}" -gt 0 ]]; then
    package="${native_packages[${#native_packages[@]} - 1]}"
    extract_root="$temporary/package"
    mkdir -p "$extract_root"
    (
      cd "$extract_root"
      ar x "$package"
      test "$(cat debian-binary)" = "2.0"
      tar -tzf control.tar.gz | grep -Fx control >/dev/null
      tar -tzf control.tar.gz | grep -Fx md5sums >/dev/null
      tar -tzf data.tar.gz | grep -Fx ./usr/bin/osmanthus >/dev/null
      tar -xzf data.tar.gz ./usr/bin/osmanthus
      ./usr/bin/osmanthus --version | grep -E '^osmanthus [0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$'
      set +e
      ./usr/bin/osmanthus check -- rm -rf /example >/dev/null
      status=$?
      set -e
      test "$status" -eq 77
    )
  fi
fi
