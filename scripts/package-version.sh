#!/usr/bin/env bash

parse_osmanthus_package_version() {
  local version="${1:?package version is required}"

  if [[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(-rc\.([0-9]+))?$ ]]; then
    OSMANTHUS_SEMVER="$version"
    OSMANTHUS_BASE_VERSION="${BASH_REMATCH[1]}"
    if [[ -n "${BASH_REMATCH[2]}" ]]; then
      OSMANTHUS_PRERELEASE="rc.${BASH_REMATCH[3]}"
      OSMANTHUS_DEB_VERSION="${OSMANTHUS_BASE_VERSION}~${OSMANTHUS_PRERELEASE}-1"
      OSMANTHUS_RPM_VERSION="$OSMANTHUS_BASE_VERSION"
      OSMANTHUS_RPM_RELEASE="0.${OSMANTHUS_PRERELEASE}"
    else
      OSMANTHUS_PRERELEASE=""
      OSMANTHUS_DEB_VERSION="${OSMANTHUS_BASE_VERSION}-1"
      OSMANTHUS_RPM_VERSION="$OSMANTHUS_BASE_VERSION"
      OSMANTHUS_RPM_RELEASE="1"
    fi
    export OSMANTHUS_SEMVER OSMANTHUS_BASE_VERSION OSMANTHUS_PRERELEASE
    export OSMANTHUS_DEB_VERSION OSMANTHUS_RPM_VERSION OSMANTHUS_RPM_RELEASE
    return 0
  fi

  echo "version must use MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-rc.NUMBER format" >&2
  return 1
}

require_clean_osmanthus_worktree() {
  local status

  if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "release package build requires a committed Git HEAD" >&2
    return 1
  fi
  status="$(git status --porcelain=v1 --untracked-files=all)"
  if [[ -n "$status" ]]; then
    echo "release package build requires a clean worktree" >&2
    return 1
  fi
}
