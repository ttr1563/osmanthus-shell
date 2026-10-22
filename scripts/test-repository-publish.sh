#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"
source scripts/repository-publish.sh

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
output_root="$temporary/repository"
mkdir -p "$output_root/metadata"
printf 'old\n' > "$output_root/metadata/current"

prepare_osmanthus_repository_stage "$output_root"
stage="$OSMANTHUS_REPOSITORY_STAGE"
test "$(cat "$stage/metadata/current")" = old
printf 'rejected\n' > "$stage/metadata/current"
discard_osmanthus_repository_stage "$output_root" "$stage"
test "$(cat "$output_root/metadata/current")" = old
test ! -e "$stage"

prepare_osmanthus_repository_stage "$output_root"
stage="$OSMANTHUS_REPOSITORY_STAGE"
printf 'new\n' > "$stage/metadata/current"
printf 'complete\n' > "$stage/metadata/signed"

publish_osmanthus_repository_stage "$output_root" "$stage"
test "$(cat "$output_root/metadata/current")" = new
test "$(cat "$output_root/metadata/signed")" = complete
test ! -e "$stage"

outside="$temporary/nested/outside"
mkdir -p "$outside"
if validate_osmanthus_repository_stage "$output_root" "$outside" 2>/dev/null; then
  echo 'non-sibling repository stage was accepted' >&2
  exit 1
fi
unexpected="$temporary/unexpected"
mkdir -p "$unexpected"
if validate_osmanthus_repository_stage "$output_root" "$unexpected" 2>/dev/null; then
  echo 'unexpected sibling repository stage was accepted' >&2
  exit 1
fi

echo 'Atomic repository tree publication verified.'
