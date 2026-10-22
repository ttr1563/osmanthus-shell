#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: scripts/package-source.sh VERSION [OUTPUT]}"
repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"
source scripts/package-version.sh

build_commit="$(git rev-parse --verify HEAD)"
manifest_version="$(git show "$build_commit:Cargo.toml" | awk -F '"' '/^version = "/ { print $2; exit }')"
if [[ "$version" != "$manifest_version" ]]; then
  echo "version $version does not match Cargo.toml $manifest_version" >&2
  exit 1
fi
parse_osmanthus_package_version "$version"

output="${2:-dist/osmanthus-${version}.tar.gz}"
mkdir -p "$(dirname "$output")"
require_new_osmanthus_artifact "$output"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
archive="$temporary/osmanthus-${version}.tar.gz"

git archive \
  --format=tar \
  --prefix="osmanthus-${version}/" \
  "$build_commit" \
  -- . ':(exclude)Formula' ':(exclude)docs/apt' ':(exclude)docs/rpm' \
  > "$temporary/source.tar"
gzip -n -9 < "$temporary/source.tar" > "$archive"

if [[ "$(git rev-parse --verify HEAD)" != "$build_commit" ]]; then
  echo "Git HEAD changed while creating the source archive" >&2
  exit 1
fi
require_new_osmanthus_artifact "$output"
install -m0644 "$archive" "$output"

sha256sum "$output"
