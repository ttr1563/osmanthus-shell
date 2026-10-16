#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: scripts/test-source-package.sh VERSION}"
repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"
source scripts/package-version.sh
parse_osmanthus_package_version "$version"

for command in awk cmp grep mktemp sha256sum sort tar; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 1
  }
done

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
first="$temporary/osmanthus-${version}-first.tar.gz"
second="$temporary/osmanthus-${version}-second.tar.gz"
listing="$temporary/listing"
prefix="osmanthus-${version}"

scripts/package-source.sh "$version" "$first" >/dev/null
scripts/package-source.sh "$version" "$second" >/dev/null
cmp -s "$first" "$second"
tar -tzf "$first" > "$listing"

test "$(awk -F/ 'NF { print $1 }' "$listing" | sort -u)" = "$prefix"
for required in \
  Cargo.lock \
  Cargo.toml \
  LICENSE \
  README.md \
  SECURITY.md \
  build.rs \
  bpf/osmanthus_lsm.bpf.c \
  docs/operations.md \
  docs/ssm.md \
  docs/windows-server.md \
  ops/logrotate/osmanthus \
  ops/ssm/osmanthus-session.json \
  ops/systemd/osmanthusd.service \
  packaging/deb/osmanthus.sources \
  packaging/rpm/osmanthus-release.spec \
  packaging/rpm/osmanthus.repo \
  packaging/rpm/osmanthus.spec \
  scripts/build-apt-repository.sh \
  scripts/build-deb.sh \
  scripts/build-rpm-repository.sh \
  scripts/build-rpm.sh \
  scripts/package-source.sh \
  scripts/package-version.sh \
  scripts/test-deb.sh \
  scripts/test-rpm.sh \
  scripts/test-installed-truncate.sh \
  scripts/test-signed-repositories.sh \
  scripts/test-source-package.sh \
  scripts/verify-apt-repository.sh \
  scripts/verify-rpm-repository.sh \
  src/bin/osmanthus-shell.rs \
  src/bin/osmanthusd.rs \
  src/main.rs; do
  grep -Fx "$prefix/$required" "$listing" >/dev/null
done

if grep -Eq "^${prefix}/(Formula/|docs/(apt|rpm)/|target/|dist/|\\.git/)" "$listing"; then
  echo "excluded content found in source archive" >&2
  exit 1
fi

archive_version="$(
  tar -xOzf "$first" "$prefix/Cargo.toml" \
    | awk -F '"' '/^version = "/ { print $2; exit }'
)"
test "$archive_version" = "$version"

echo "Reproducible source archive verified: $(sha256sum "$first" | awk '{ print $1 }')"
