# Linux Workspace APT releases

The headless install unit contains `conclave-service`, `conclave-workspace`, and
one canonical generic CLI Worker Engine. Provider CLIs are installed separately.
The optional Flutter desktop bundle continues to use its existing Linux build.

## Build from macOS or Linux

Dart 3.8+ supports cross-compiling Linux x64/arm64 executables. Install Flutter,
Node.js, Python 3 and dpkg (`brew install dpkg` on macOS). Supply the production
public application-release trust roots, then:

```bash
export CONCLAVE_RELEASE_TRUST_KEYS_JSON='YOUR_PRODUCTION_PUBLIC_ROOTS_JSON'
bash scripts/build-workspace-linux-headless.sh x64
bash scripts/package-workspace-linux.sh x64
bash scripts/build-workspace-linux-headless.sh arm64
bash scripts/package-workspace-linux.sh arm64
```

Outputs are under `dist/conclave-workspace`: `linux-<arch>/service`, headless
`.tar.gz` bundles, and `deb/conclave-workspace_<version>_<amd64|arm64>.deb`.
`CONCLAVE_WORKSPACE_VERSION` overrides the pubspec version at compile/package
time; use a new version for every release. The target OS/architecture inputs
`CONCLAVE_BUILD_TARGET_OS=linux` and `CONCLAVE_BUILD_TARGET_ARCH=x64|arm64` are
build-only. Target Engine artifacts live under `dist/cli-worker-engine` and do
not replace native Workspace or Profile Lab assets. The canonical Engine script
remains the sole source of Engine builds. Headless packages set the build-time
`CONCLAVE_WORKSPACE_PACKAGE_MANAGER=apt` so the application updater cannot compete
with APT. Never promote candidates containing CI fixture trust anchors.

Cross-compiling proves compilation, not Linux behavior. Test on the target OS.
The `Release Linux Workspace` workflow builds on Ubuntu 22.04 for amd64 and
arm64, analyzes Workspace, tests registration/IPC/Linux adapters, signs a disposable
test repository, and performs real APT installation, upgrade, service IPC,
SIGTERM shutdown and package removal. It verifies that installation identity,
session files and Work Root data survive upgrade/removal.

Local checks:

```bash
python3 scripts/release/test-apt-repository.py # needs dpkg and GnuPG
# Linux only, on a disposable machine with sudo, after building a package:
bash scripts/test-workspace-linux-package.sh x64
```

## Provision public hosting and signing

APT needs a static HTTPS repository, not registration in Ubuntu's official
archive. Keep it separate from the private source repository. A dedicated public
GitHub repository (for example `nohainc/conclave-packages`) can serve its
`gh-pages` branch through GitHub Pages. Initialize that branch with an index page
and enable Pages for the branch root. Never publish application source, signing
material, or user data to this repository. GitHub Pages size limits apply; monitor
repository growth and migrate static hosting before approaching those limits.

Generate a dedicated OpenPGP signing key in protected release infrastructure.
Keep a secured offline backup and record its full fingerprint. Do not reuse the
Workspace application metadata Ed25519 key. Export its public binary key as
`conclave-archive-keyring.gpg`; distribute the fingerprint through a separately
trusted publication channel. The repository generator exports only public key
material, signs `InRelease` and `Release.gpg`, and verifies its signature.

Configure these values in the private source repository:

| Scope | Name | Value |
| --- | --- | --- |
| Repository variable | `CONCLAVE_RELEASE_TRUST_KEYS_JSON` | Existing production public application-release roots |
| `workspace-linux-release` environment variable | `CONCLAVE_APT_SIGNING_FINGERPRINT` | Full OpenPGP signing fingerprint |
| `workspace-linux-release` environment variable | `CONCLAVE_APT_REPOSITORY` | Dedicated `owner/repository` for package hosting |
| `workspace-linux-release` environment secret | `CONCLAVE_APT_PRIVATE_KEY` | ASCII-armored signing private key for noninteractive GPG signing |
| `workspace-linux-release` environment secret | `CONCLAVE_APT_PUBLISH_TOKEN` | Dedicated token with contents write access only to the package repository |

Protect the environment with release-operator approval and restrict deployment
to `main`. The signing key must be available noninteractively in this protected
environment; private key material is imported only into an ephemeral `0700`
GnuPG directory and removed after publishing. Never print it. A publisher token
is needed because the source repository's GITHUB_TOKEN cannot write a separate
repository, and its pushes would not trigger the target Pages build.

## Publish and upgrade

Dispatch `Release Linux Workspace` from `main` with an immutable version and
`publish=true`. Publication requires successful push-triggered repository CI for
that exact commit, followed by successful package tests for both architectures.
The release job downloads those tested packages without rebuilding them, clones
the existing public repository, adds the new versions, generates signed indexes,
and pushes a regular fast-forward commit to `gh-pages`. Concurrent releases are
serialized. Missing keys/hosting/trust roots fail closed. A non-publish run uses
fixture roots only when production roots are not configured and retains candidates
as private workflow artifacts.

The static tree contains `pool`, `dists/stable`, a public key and `.nojekyll`.
Existing versions and by-hash indexes are retained for rollback and clients
mid-update. Replacing an existing version/architecture with different bytes is
rejected. `Release` does not expire during quiet release periods; it has a signed
publication date and is regenerated for each release. Upload to other static
hosts by building a staging copy of the existing repository and atomically
switching the served tree. Never run the generator against a live served tree.

Wait for the package repository's Pages deployment to succeed, download its
public `InRelease` and verify it with the recorded signing key, then perform a
fresh install and upgrade from the public HTTPS endpoint on a separate Ubuntu
host. Successful git push alone is not proof of public availability. See the
[Linux operator guide](../operations/WORKSPACE_LINUX.md) for installation commands.

APT upgrades require a user-service stop/start around package replacement; no
root maintainer script touches running users' assignments. Existing installation
IDs, registration, runtime credentials, Work Root, Profiles and sessions remain
in the original state directory. No data migration is introduced. An archive
install must stop/unregister its old user unit before registering the `/usr/lib`
service location; the existing manager refuses to silently change a unit pointing
at another executable. Reboot/linger, real provider assignments and browser
approval against production still need target-host acceptance evidence.
