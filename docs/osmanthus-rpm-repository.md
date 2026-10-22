# Osmanthus RPM repository runbook

> The Osmanthus repository is not public yet. This is the release-engineering
> runbook for the first Linux release. The old Onyx v0.1.3 repository and key
> are historical and must not sign or distribute Osmanthus.

The stable repository URL is reserved as
`https://ttr1563.github.io/osmanthus-shell/rpm/`. Release candidates may be
published as signed GitHub Release assets, but the stable DNF channel is not
updated until the RC acceptance and observation gates pass.

## Version mapping

| Cargo/tag | RPM `Version-Release` |
| --- | --- |
| `0.2.0-rc.1` / `v0.2.0-rc.1` | `0.2.0-0.rc.1` |
| `0.2.0` / `v0.2.0` | `0.2.0-1` |

RPM therefore orders the stable build after every RC. The authoritative mapping
is `scripts/package-version.sh`.

## Repository layout

```text
docs/rpm/
├── RPM-GPG-KEY-OSMANTHUS
├── SHA256SUMS
├── SHA256SUMS.asc
├── osmanthus-release-1-1.noarch.rpm
└── al2023/
    ├── x86_64/{Packages,repodata}
    └── aarch64/{Packages,repodata}  # only after native acceptance
```

The repository builder discovers accepted `x86_64` and `aarch64` package
directories independently, signs each RPM, and generates metadata with one
worker. An architecture is not advertised merely because the spec can build it.

## Build and verify

```console
scripts/build-rpm.sh 0.2.0-rc.1 dist/rpm/al2023
scripts/test-rpm.sh 0.2.0-rc.1 dist/rpm/al2023/x86_64
```

The package builder requires a committed clean worktree and refuses to replace
an existing same-version artifact. Remove disposable local test output
explicitly before rebuilding it; for any published or accepted artifact, use a
new RC or patch version instead. It also requires a native Linux `x86_64` or
`aarch64` build and rejects an RPM target macro that does not match the host.

Place accepted packages in `docs/rpm/al2023/<architecture>/Packages/` only on
the release branch. Sign with the same dedicated Osmanthus identity used by the
APT repository:

```console
export OSMANTHUS_GPG_HOME=/secure/path/to/osmanthus-signing-home
export OSMANTHUS_GPG_KEY_ID=<full-fingerprint>
export OSMANTHUS_GPG_PUBLIC_KEY=/secure/path/to/RPM-GPG-KEY-OSMANTHUS
scripts/build-rpm-repository.sh docs/rpm
scripts/verify-rpm-repository.sh docs/rpm/al2023/x86_64 docs/rpm/RPM-GPG-KEY-OSMANTHUS
```

Use `scripts/test-signed-repositories.sh` with disposable roots below `dist`
before involving the release key. Its one-day test key and private GnuPG home
are removed when the test exits.

The verifier checks package signatures, the detached `repomd.xml` signature,
the signed checksum manifest, RPM identities, and a DNF metadata refresh from
an isolated install root. Keep the private key and passphrase outside Git,
shell arguments, artifacts, and logs.

Repository regeneration signs only previously unsigned packages. An existing
package or bootstrap RPM must already verify with the configured Osmanthus key;
otherwise generation stops instead of replacing its signature. The ephemeral
repository test runs generation twice and confirms that every package checksum
is unchanged.
Before the first signature is written, the builder also requires the public key
file to contain exactly one primary key whose full fingerprint matches the
selected secret signing key. A mismatch fails without modifying an unsigned RPM.

## Clean-host release gate

On every advertised architecture:

1. Verify the HTTPS-downloaded key fingerprint against the release notes.
2. Install `osmanthus-release-1-1.noarch.rpm`, refresh DNF metadata, and install
   `osmanthus`.
3. Confirm the daemon is `Enforcing`, then exercise protected delete, direct
   truncate, opt-in write, maintenance scoping, audit failure, monitored login
   rollback, authenticated decommission, and uninstall.
4. Upgrade from the previous installable version and verify policy/audit state
   preservation.
5. Run an explicit `dnf downgrade` to the immediately previous package and
   repeat a protected delete. For an incompatible BPF ABI, follow the
   authenticated decommission/fresh-attach runbook; never remove individual
   pins.
6. Confirm the package removal retains policy and audit evidence and removes
   the unit, binaries, and decommissioned BPF pins.

## Public installation and rollback

These commands become valid only after stable publication:

```console
curl -fsSLo /tmp/RPM-GPG-KEY-OSMANTHUS \
  https://ttr1563.github.io/osmanthus-shell/rpm/RPM-GPG-KEY-OSMANTHUS
# Compare the full fingerprint with the release notes before import.
sudo rpm --import /tmp/RPM-GPG-KEY-OSMANTHUS
sudo dnf install \
  https://ttr1563.github.io/osmanthus-shell/rpm/osmanthus-release-1-1.noarch.rpm
sudo dnf install osmanthus
rm -f /tmp/RPM-GPG-KEY-OSMANTHUS
```

Keep the current and immediately previous RPM in repository metadata. Rollback
is explicit:

```console
sudo dnf --showduplicates list osmanthus
sudo dnf downgrade osmanthus-<previous-version-release>
```

Never replace an existing tag or RPM with different bytes. Publish a new
RC/patch or revert the repository publication through a protected PR. Rotate
keys through an overlap release; suspected compromise requires a new explicit
trust bootstrap and incident notice.
