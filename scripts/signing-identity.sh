#!/usr/bin/env bash

require_osmanthus_signing_identity() {
  local public_key="${1:?public key path is required}"
  local gpg_home="${2:?GnuPG home is required}"
  local signing_key="${3:?signing key is required}"
  local public_listing secret_listing
  local -a public_fingerprints=() secret_fingerprints=()

  public_listing="$(gpg --batch --with-colons --import-options show-only --import "$public_key")"
  secret_listing="$(GNUPGHOME="$gpg_home" gpg --batch --with-colons \
    --list-secret-keys "$signing_key")"
  mapfile -t public_fingerprints < <(
    awk -F: '$1 == "pub" { primary=1; next } primary && $1 == "fpr" { print $10; primary=0 }' \
      <<<"$public_listing"
  )
  mapfile -t secret_fingerprints < <(
    awk -F: '$1 == "sec" { primary=1; next } primary && $1 == "fpr" { print $10; primary=0 }' \
      <<<"$secret_listing"
  )

  if [[ "${#public_fingerprints[@]}" -ne 1 ]]; then
    echo "Osmanthus public key file must contain exactly one primary key" >&2
    return 1
  fi
  if [[ "${#secret_fingerprints[@]}" -ne 1 ]]; then
    echo "OSMANTHUS_GPG_KEY_ID must select exactly one secret primary key" >&2
    return 1
  fi
  if [[ "${public_fingerprints[0]}" != "${secret_fingerprints[0]}" ]]; then
    echo "Osmanthus public key does not match the configured signing identity" >&2
    return 1
  fi
}
