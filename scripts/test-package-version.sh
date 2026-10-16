#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"
source scripts/package-version.sh

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

parse_osmanthus_package_version 0.2.0-rc.1
test "$OSMANTHUS_DEB_VERSION" = '0.2.0~rc.1-1'
test "$OSMANTHUS_RPM_VERSION" = '0.2.0'
test "$OSMANTHUS_RPM_RELEASE" = '0.rc.1'

parse_osmanthus_package_version 0.2.0
test "$OSMANTHUS_DEB_VERSION" = '0.2.0-1'
test "$OSMANTHUS_RPM_VERSION" = '0.2.0'
test "$OSMANTHUS_RPM_RELEASE" = '1'

if command -v dpkg >/dev/null; then
  dpkg --compare-versions '0.2.0~rc.1-1' lt '0.2.0-1'
fi
if command -v rpm >/dev/null; then
  test "$(rpm --eval '%{lua:print(rpm.vercmp("0.rc.1", "1"))}')" -lt 0
fi

if parse_osmanthus_package_version 0.2.0-beta.1 2>/dev/null; then
  echo 'unsupported prerelease version was accepted' >&2
  exit 1
fi

(
  cd "$temporary"
  git init --quiet
  git config user.name 'Osmanthus package test'
  git config user.email 'osmanthus-package-test@example.invalid'
  printf 'tracked\n' > tracked
  git add tracked
  git commit --quiet -m initial
  require_clean_osmanthus_worktree

  printf 'changed\n' > tracked
  if require_clean_osmanthus_worktree 2>/dev/null; then
    echo 'modified tracked release input was accepted' >&2
    exit 1
  fi
  git restore tracked

  printf 'untracked\n' > untracked
  if require_clean_osmanthus_worktree 2>/dev/null; then
    echo 'untracked release input was accepted' >&2
    exit 1
  fi
)
