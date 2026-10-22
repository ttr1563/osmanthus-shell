# Osmanthus APT repository runbook

> The Osmanthus repository is not public yet. The commands in this document are
> release-engineering procedures for `v0.2.0-rc.1` and later. The existing
> public Onyx v0.1.3 repository is a different product and signing identity.

The stable repository URL is reserved as
`https://ttr1563.github.io/osmanthus-shell/apt/`. A release candidate may be
distributed as a signed GitHub Release asset, but it is not added to the stable
APT channel. Before the first stable publication, the same candidate packages
and repository metadata must pass the local and clean-host tests below.

## Version mapping

Cargo uses SemVer. Debian uses its native pre-release ordering:

| Cargo/tag | Debian package version |
| --- | --- |
| `0.2.0-rc.1` / `v0.2.0-rc.1` | `0.2.0~rc.1-1` |
| `0.2.0` / `v0.2.0` | `0.2.0-1` |

This guarantees that APT treats the stable package as newer than the release
candidate. `scripts/package-version.sh` is the authoritative mapping and only
accepts stable or `rc.NUMBER` versions.

## Repository layout

```text
docs/apt/
├── osmanthus.asc
├── osmanthus.sources
├── SHA256SUMS
├── SHA256SUMS.asc
├── dists/stable/
│   ├── InRelease
│   ├── Release
│   ├── Release.gpg
│   └── main/
│       ├── binary-amd64/{Packages,Packages.gz}
│       └── binary-arm64/{Packages,Packages.gz}
└── pool/main/o/osmanthus/
    ├── osmanthus_<version>_amd64.deb
    └── osmanthus_<version>_arm64.deb
```

Metadata is generated only for architectures whose native package is present.
Do not copy an amd64 package to the arm64 filename or cross-package an embedded
BPF object. Each architecture must be built and accepted natively.

## Build and verify

Build packages on their native Linux hosts and transfer them by a verified
SHA-256 digest into the release worktree:

```console
scripts/build-deb.sh 0.2.0-rc.1 dist/deb
scripts/test-deb.sh 0.2.0-rc.1 dist/deb
```

The package builder requires a committed clean worktree and refuses to replace
an existing same-version artifact. Remove disposable local test output
explicitly before rebuilding it; for any published or accepted artifact, use a
new RC or patch version instead.

Place accepted artifacts below `docs/apt/pool/main/o/osmanthus/` only on the
release branch. Use a dedicated Osmanthus package-signing key. The private key,
passphrase, TOTP values, and audit records must never enter Git, command-line
arguments, Pages artifacts, or logs.

The repository builder verifies that the public key file contains exactly one
primary key and that its full fingerprint matches the selected secret signing
key before writing repository metadata.

```console
export OSMANTHUS_GPG_HOME=/secure/path/to/osmanthus-signing-home
export OSMANTHUS_GPG_KEY_ID=<full-fingerprint>
export OSMANTHUS_GPG_PUBLIC_KEY=/secure/path/to/RPM-GPG-KEY-OSMANTHUS
scripts/build-apt-repository.sh docs/apt
scripts/verify-apt-repository.sh docs/apt
```

Before using the release key, the same builders can be exercised against
packages below `dist` with an automatically deleted one-day test key:

```console
scripts/test-signed-repositories.sh dist/repository/apt dist/repository/rpm
```

The public key fingerprint in release notes must match `osmanthus.asc` and the
RPM repository key. `InRelease`, `Release.gpg`, and `SHA256SUMS.asc` are all
verified from a fresh temporary GnuPG home.

## Clean-host release gate

For every advertised Debian/Ubuntu version and architecture:

1. Fetch the public key and `osmanthus.sources` over the intended HTTPS URL.
2. Confirm the announced full key fingerprint before installing it.
3. Run `apt-get update`, install Osmanthus, and confirm `osmanthusd` reports
   `Kernel backend: Enforcing`.
4. Verify protected delete, direct truncate, opt-in non-truncating write,
   scoped maintenance, audit evidence, monitored login rollback, authenticated
   decommission, and uninstall.
5. Upgrade from the immediately previous installable version without losing
   policy or audit state.
6. Explicitly install the immediately previous version, restart the daemon,
   and repeat a protected delete. If its BPF ABI is incompatible, use the
   documented authenticated decommission/fresh-attach procedure instead of
   deleting pins.
7. Confirm removal retains `/etc/osmanthus` and `/var/log/osmanthus`, while
   binaries, the unit, and BPF pins are absent.

Do not treat package inspection or a container without BPF LSM as a substitute
for this installed-kernel test.

## Public installation and rollback

These commands become valid only after the stable repository is published:

```console
sudo install -d -m0755 /etc/apt/keyrings /etc/apt/sources.list.d
curl -fsSLo /tmp/osmanthus.asc https://ttr1563.github.io/osmanthus-shell/apt/osmanthus.asc
# Compare the full fingerprint with the release notes before installation.
sudo install -m0644 /tmp/osmanthus.asc /etc/apt/keyrings/osmanthus.asc
curl -fsSLo /tmp/osmanthus.sources https://ttr1563.github.io/osmanthus-shell/apt/osmanthus.sources
sudo install -m0644 /tmp/osmanthus.sources /etc/apt/sources.list.d/osmanthus.sources
sudo apt-get update
sudo apt-get install osmanthus
rm -f /tmp/osmanthus.asc /tmp/osmanthus.sources
```

Keep the current and immediately previous package in the pool. Rollback is
explicit and must name the Debian version shown by `apt-cache policy`:

```console
apt-cache policy osmanthus
sudo apt-get install osmanthus=<previous-debian-version>
```

Never rewrite an existing tag or replace an immutable package with different
bytes. Publish a new RC/patch or revert the repository publication through a
PR. Key rotation requires an overlap release; suspected compromise requires a
new explicit trust bootstrap and an incident notice.
