# Headless Linux package acceptance

Recorded 2026-10-26. These are development candidates, not a public release.
The public application trust roots used for this run are the existing CI fixture
roots; they must not be promoted to production.

## Retained evidence

| Check | Result |
| --- | --- |
| Apple Silicon macOS, Dart 3.13.7 | Service, CLI and canonical Engine cross-compiled to Linux x64 and ARM64 |
| ELF validation and Debian package inspection | Both architecture checks passed; payload owned by root, executables 0755, command symlinks resolve beside service/Engine |
| Workspace component | Analysis passed; 591 tests passed, 21 platform/acceptance skips; compiled headless service started and stopped |
| Focused CLI, headless auth, manager IPC and Linux adapters | 25 tests passed; analysis passed after final CLI additions |
| Engine dependency/component validation | Protocol, Profile and runtime package checks passed; Engine suite passed with serial execution: 106 tests, 2 platform skips |
| Signed APT repository contract | Signature verification, package hashes, version retention, by-hash indexes, immutable-version rejection and tamper rejection passed |
| Shell and Actions syntax | shellcheck, bash syntax and actionlint passed |
| Ubuntu 22.04 ARM64 container, native ARM64 Linux VM on this Mac | Signed APT install/upgrade/remove, foreground service lifecycle and authenticated CLI IPC passed |
| Ubuntu 22.04 amd64 container, QEMU emulation in that VM | Same package lifecycle and IPC checks passed |

The package smoke script installs an older package from a signed `file:` APT
repository, creates installation identity, session and Work Root sentinels,
updates the repository, upgrades through APT, then checks the current service
version, APT ownership of application updates, service health, Worker listing,
Engine executable startup and graceful SIGTERM shutdown. Package removal leaves
identity, session and user work sentinels intact. The test uses an ordinary Linux
account with sudo only for package-manager operations; it does not use production
credentials or execute real provider work.

Workspace's component command passed unchanged. The parallel Engine component
command hit short subprocess timeouts in two separate runs; both affected focused
tests passed independently and the complete Engine suite passed serially. No
provider or Engine source was changed to hide timing failures.

The attempted GitHub Ubuntu workflow was blocked before its first job step:
GitHub reported failed account payments or a spending limit requiring attention.
See [the attempted run](https://github.com/nohainc/conclave/actions/runs/40318160146).
Local Linux container checks supplied executable package evidence despite that
runner blocker. They do not replace the main-branch CI requirement for publication.

## Production release 1.0.3

Published on 2026-10-26 from `15233c7a59d19c488124b4ff1208378293dbf993`:

- [Main CI](https://github.com/nohainc/conclave/actions/runs/40323885933) passed.
- [Production release workflow](https://github.com/nohainc/conclave/actions/runs/40324479519)
  passed native builds, signed test-repository upgrades, production signing,
  GitHub Pages deployment, and fresh public HTTPS APT installation on both
  Ubuntu 22.04 amd64 and ARM64 runners.
- [Public APT repository](https://nohainc.github.io/syntila/) and
  [GitHub release](https://github.com/nohainc/conclave/releases/tag/workspace-linux-v1.0.3)
  provide version 1.0.3. Both downloaded Debian packages were independently
  verified against the signature-bound SHA256 indexes after deployment.
- Dedicated production OpenPGP signing material and independent application
  trust roots are configured. Signing and deployment environments are restricted
  to main. No personal publishing token is required.

No CI fixture key is trusted by these production packages. The private backups
remain outside the source checkout; see the
[release operations guide](../deployment/WORKSPACE_LINUX_RELEASES.md).

## Remaining target-host qualification

- Qualify systemd user registration/start, reboot/linger, provider credentials
  and actual assignments on a target Ubuntu host.
- Exercise browser approval against production Cloud on that host. The local
  registration tests cover fresh/matching ownership, cross-account refusal,
  credential non-disclosure and cancellation with fixtures.

No data migration is introduced. Existing installation, Cloud identity, runtime
credential, registry, Profiles, Engine state, sessions and Work Root stay in place.
Archive installations must explicitly switch their systemd unit to the packaged
service path; package installation never silently changes existing units.
