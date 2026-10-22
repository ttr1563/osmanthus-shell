#!/usr/bin/env bash

prepare_osmanthus_repository_stage() {
  local output_root="${1:?repository output root is required}"
  local output_parent
  local output_name

  if [[ ! -d "$output_root" || -L "$output_root" ]]; then
    echo "repository output root must be an existing non-symlink directory: $output_root" >&2
    return 1
  fi
  output_root="$(realpath -e "$output_root")"
  output_parent="$(dirname "$output_root")"
  output_name="$(basename "$output_root")"
  OSMANTHUS_REPOSITORY_STAGE="$(mktemp -d "$output_parent/.${output_name}.osmanthus-stage.XXXXXX")"
  if ! cp -a "$output_root/." "$OSMANTHUS_REPOSITORY_STAGE/"; then
    rm -rf -- "$OSMANTHUS_REPOSITORY_STAGE"
    OSMANTHUS_REPOSITORY_STAGE=""
    return 1
  fi
  export OSMANTHUS_REPOSITORY_STAGE
}

validate_osmanthus_repository_stage() {
  local output_root="${1:?repository output root is required}"
  local stage="${2:?repository stage is required}"
  local output_parent
  local output_name

  output_root="$(realpath -e "$output_root")"
  stage="$(realpath -e "$stage")"
  output_parent="$(dirname "$output_root")"
  output_name="$(basename "$output_root")"
  if [[ "$(dirname "$stage")" != "$output_parent" ]]; then
    echo "repository stage must be a sibling of the output root" >&2
    return 1
  fi
  case "$(basename "$stage")" in
    ".${output_name}.osmanthus-stage."*) ;;
    *)
      echo "repository stage has an unexpected name: $stage" >&2
      return 1
      ;;
  esac
}

discard_osmanthus_repository_stage() {
  local output_root="${1:?repository output root is required}"
  local stage="${2:?repository stage is required}"

  [[ -e "$stage" || -L "$stage" ]] || return 0
  validate_osmanthus_repository_stage "$output_root" "$stage"
  rm -rf -- "$stage"
}

publish_osmanthus_repository_stage() {
  local output_root="${1:?repository output root is required}"
  local stage="${2:?repository stage is required}"

  validate_osmanthus_repository_stage "$output_root" "$stage"
  output_root="$(realpath -e "$output_root")"
  stage="$(realpath -e "$stage")"
  python3 - "$output_root" "$stage" <<'PY'
import ctypes
import os
import sys

AT_FDCWD = -100
RENAME_EXCHANGE = 2
output_root = os.fsencode(sys.argv[1])
stage = os.fsencode(sys.argv[2])
libc = ctypes.CDLL(None, use_errno=True)
renameat2 = libc.renameat2
renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameat2.restype = ctypes.c_int
if renameat2(AT_FDCWD, output_root, AT_FDCWD, stage, RENAME_EXCHANGE) != 0:
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error))
PY
  discard_osmanthus_repository_stage "$output_root" "$stage"
}
