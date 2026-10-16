#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: scripts/package-source.sh VERSION [OUTPUT]}"
repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"
source scripts/package-version.sh

manifest_version="$(git show HEAD:Cargo.toml | awk -F '"' '/^version = "/ { print $2; exit }')"
if [[ "$version" != "$manifest_version" ]]; then
  echo "version $version does not match Cargo.toml $manifest_version" >&2
  exit 1
fi
parse_osmanthus_package_version "$version"

output="${2:-dist/osmanthus-${version}.tar.gz}"
mkdir -p "$(dirname "$output")"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

git archive \
  --format=tar \
  --prefix="osmanthus-${version}/" \
  HEAD \
  -- . ':(exclude)Formula' ':(exclude)docs/apt' ':(exclude)docs/rpm' \
  > "$temporary/source.tar"
gzip -n -9 < "$temporary/source.tar" > "$output"

sha256sum "$output"
