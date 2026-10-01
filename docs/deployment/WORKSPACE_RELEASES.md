# Workspace, Engine, and Tool Profile Release Operations

**Architecture v8:** the active target uses one generic CLI Worker Engine plus
signed Tool Profile releases. Per-provider native ChatGPT/Gemini Worker
releases documented later in this file are migration history until removed.

## v8 release classes

The v8 release model has three distinct release classes:

1. **Workspace application release** — signed/notarized desktop application.
2. **CLI Worker Engine release** — generic native Dart executable; initially may
   be bundled with Workspace, later may support independent signed rollout.
3. **Tool Profile release** — small immutable signed provider integration
   payload promoted through Draft/Testing/Beta/Stable.

Provider CLI software remains installed/updated by the user/provider.

### Tool Profile release flow

~~~text
create immutable Profile release
-> static schema/security validation
-> fixture tests
-> sign payload
-> publish Draft
-> promote to Testing
-> real provider acceptance
-> Beta optional
-> Stable
~~~

Stable promotion changes lifecycle/pointers, never the signed Profile payload.

The Ed25519 signature binds the canonical full Profile payload digest and an
explicit identity envelope: publisher, signing key ID, Profile definition and
release version, logical Worker, schema and Engine compatibility, provider CLI
name, and supported provider CLI versions. Workspace recomputes the digest,
compares the envelope claims to Cloud metadata, then checks its trust roots and
refreshed revocations before Engine admission. Lifecycle/channel and audit
metadata remain independently mutable and cannot change the signed behavior.

Workspace stores releases in its managed `Profiles/` directory, with one
versioned directory per Profile Definition, a signed release metadata sidecar,
and a per-definition `release-state.json`. Stable catalog sync refreshes the
Cloud revocation snapshot first, validates the complete Profile v1 schema and
signature before writing, then updates active/last-known-good pointers. The
default cache retains three releases, including active and last-known-good.
Revoked or locally altered releases are removed from the usable cache and
active pointers move to the newest remaining verified version. Profile sync is
periodic and independent of Engine or Workspace application updates.

Profile rollback selects a previous trusted compatible release. Revoked releases
are never eligible for activation/rollback.

### Generic Engine release flow

The signed/notarized Workspace application archive is the initial trust
boundary for the bundled Engine. Each Workspace release contains one
platform-specific Engine build. Workspace bounds and hashes the asset, then
materializes it at
`<ApplicationSupport>/Engines/cli_worker/<engine-version>-<sha256>/`. The
Engine version is independently checked during Protocol 4.0 initialization
and recorded in diagnostics. Workspace rehashes a cached executable on
startup and replaces altered bytes from its bundled copy. Failure to load or
materialize the asset makes the Engine unavailable.

There is no separate Engine catalog, signing key, Cloud lifecycle, or local
active/LKG pointer in this release model. Updating or rolling back the Engine
means updating or restoring the complete signed/notarized Workspace release.
The current Workspace app update path is manual until its drain, staging,
restart, health-check, and rollback transaction has passed end-to-end
acceptance (see Production readiness limit below). Recovery from a bad Engine
release therefore uses the prior verified Workspace archive; Workspace does
not fall back to another cached Engine automatically.

If independent Engine delivery becomes necessary later, it must add immutable
signed per-platform artifacts, trust and revocation checks, candidate Engine
initialization and passive health admission, atomic activation, and active/LKG
rollback. This is optional follow-on work and does not block v8.


**Migration-only v2 release tooling:** signed platform-specific provider Worker
executables published as Worker release v2 records. Neither those binaries nor
their release records define the v8 release contract. The Node adapter workflow
and its signing configuration below are retained as migration history only.
The v8 release contract is the generic CLI Worker Engine plus signed Tool
Profile Releases described above.

## Legacy adapter release tooling

The manually dispatched [V7 adapter release workflow](../../.github/workflows/release-v7-adapter.yml)
is retained only as migration history. Its releases are no longer part of the
Cloud catalog. Migration `0035_worker_releases.sql` drops
`v7_adapter_releases`; migration `0050_remove_native_worker_release_catalog.sql`
drops the native Worker package catalog. Neither release table is recreated.

For a publish run, provide `source` as a repository-relative adapter package
directory, for example:

```text
packages/worker-manifest/adapters/codex
packages/worker-manifest/adapters/antigravity
packages/worker-manifest/adapters/claude-code
packages/worker-manifest/adapters/ollama
packages/worker-manifest/adapters/openai-api
packages/worker-manifest/adapters/gemini-api
packages/worker-manifest/adapters/anthropic-api
```

These source paths describe the retired adapter workflow only. They do not
publish native Worker releases.

The legacy adapter test command is:

```sh
pnpm worker-adapters:test
```

## Retired v2 native provider Worker release catalog

This catalog is migration history only. Migration `0049` drops
`worker_releases` from the v8 database after Tool Profile tables are created;
`v7_adapter_releases` is also absent from the final schema. The old API routes
and publish workflow must not be used for v8 releases. Workspace receives
signed Tool Profile releases through the Profile registry described above.

Older migration files remain in the ordered D1 history so already-initialized
development databases can advance safely. The old `/api/worker-releases` paths
return HTTP 410; shared Workspace/Profile signing trust is served by
`/api/release-trust`. Clean-room and upgraded v8 databases finish with no
native provider Worker release table or package rows.

## macOS Workspace releases

The manually dispatched [Workspace macOS release workflow](../../.github/workflows/release-workspace-macos.yml)
builds the `.app` with the requested immutable version, runs Flutter analysis
and tests, signs with Developer ID, notarizes, verifies the archive, signs
release metadata with the separate Workspace Ed25519 key, publishes it, then
downloads and verifies metadata and archive digest.

Required protected configuration is declared by the workflow:

- GitHub Environment `workspace-release`;
- `CONCLAVE_MACOS_CERTIFICATE_P12`, certificate password, Apple ID, Team ID,
  and app-specific password secrets;
- `CONCLAVE_WORKSPACE_ED25519_SEED` secret and
  `CONCLAVE_WORKSPACE_SIGNING_KEY_ID` variable;
- `CONCLAVE_ADAPTER_ED25519_SEED` secret and
  `CONCLAVE_ADAPTER_SIGNING_KEY_ID` variable are required only by the legacy
  Workspace app-asset adapter packaging workflow; they are not required by the
  native Worker release workflow;
- `CONCLAVE_RELEASE_PUBLISH_TOKEN` secret and `CLOUD_API_URL` variable;
- `CONCLAVE_RELEASE_TRUST_KEYS_JSON` variable containing public roots.

The previous app-asset adapter packaging path is retired as native Worker
release installation is implemented. Apple app signing/notarization remains
separate from Worker package signing and Conclave's signed Workspace release
metadata.

## Production readiness limit

Cloud discovery, archive verification, and release publication are implemented.
The Workspace app does not yet perform a complete native `.app` update
transaction: active-work drain, bundle staging/replacement, restart, post-start
health check, and rollback have not passed an end-to-end update test. Until
that gate closes, wait for active assignments to reach zero, quit Workspace,
install the downloaded and verified notarized app archive through macOS, reopen
Workspace, and confirm that it reconnects to Cloud. This is a manual
installation procedure; do not claim automatic macOS app updating is
production-ready.

## Trust and incident operations

Use [Release Trust and Rotation](../security/RELEASE_TRUST_AND_ROTATION.md) for
key separation, overlap rotation, revocation, and recovery constraints. Do not
store release seeds or publication tokens in the repository, package archive,
desktop artifact, or workflow output.

## Migration-only Worker Runtime v2 release workflow

This section is an archival record of predecessor procedures, not an approved
way to add or publish a normal CLI integration. The Phase 31 acceptance gate in
the [v8 implementation plan](../roadmaps/ARCHITECTURE_V8_IMPLEMENTATION.md)
must pass before remaining provider-specific executables and publishing code
are removed.

ADR-017 records independently versioned platform-specific native Worker
releases. This section documents existing migration tooling and must not be
used to define or extend the v8 runtime. Retained local publishing artifacts
are not supported: Cloud returns HTTP 410 for the old package endpoints, and
the v8 database has no native package catalog. Phase 31 removes remaining
provider-specific binaries and publishing code after generic Engine/Profile
real-provider, activation/rollback, and Work v1 acceptance.

Historical v2 Worker release flow:

~~~text
compile native Dart Worker per platform/architecture
-> test executable/protocol
-> package immutable release
-> digest + Ed25519 sign
-> publish R2 + worker_releases catalog
-> Workspace downloads into staging
-> verify signature/digest/platform/protocol/state compatibility
-> self-check + passive provider probe
-> atomically activate
-> retain previous last-known-good version
~~~

Worker release identity includes `(worker_type_id, version, platform)`. Workspace and Worker versions remain independent. The user can stay on, update, pin, or roll back one Worker without changing the Workspace application or the other Worker. See [Worker Runtime v2](../architecture/WORKER_RUNTIME_V2.md) and its [implementation plan](../roadmaps/WORKER_RUNTIME_V2_IMPLEMENTATION.md).

### Historical publishing of native ChatGPT and Gemini Workers

This workflow exists only for migration/reference builds. Do not publish new
provider-specific Worker releases as a v8 integration strategy.

Run the manually dispatched [native Worker release workflow](../../.github/workflows/release-worker-v2.yml)
with one shared semantic version and release channel. It builds and tests both
Workers on macOS arm64/x64, Linux arm64/x64, and Windows x64, then signs and
publishes all ten `(Worker Type, version, platform)` artifacts. The executable
version is embedded at compile time; published release identities are
immutable. Re-running a partially completed publish is safe because Cloud
accepts an identical artifact as already published and rejects changed bytes
for an existing identity.

The workflow uses Dart SDK `3.12.2` and the committed lockfiles. It requires:

- `CONCLAVE_CLOUD_URL` variable;
- `CONCLAVE_WORKER_PUBLISHER` and `CONCLAVE_WORKER_SIGNING_KEY_ID` variables;
- `CONCLAVE_RELEASE_PUBLISH_TOKEN` secret with permission to publish Worker
  releases;
- `CONCLAVE_WORKER_SIGNING_SEED` secret containing the base64-encoded raw
  32-byte Ed25519 seed. Its public key must already be trusted by Cloud and
  Workspace under the matching publisher/key ID.

Dispatch from GitHub Actions, or use the single CI entry point after
authenticating the GitHub CLI:

```sh
gh workflow run release-worker-v2.yml \
  -f worker_version=1.4.2 \
  -f release_channel=stable
```

The signed manifest and archive hash authenticate the installed executable.
This workflow does not apply Apple Developer ID or Windows Authenticode
signatures; add platform signing if the distribution channel or operating
system policy requires it. Signing credentials and publication tokens are
never written to artifacts or logs.

### Migration-only local native Worker development

These commands build the superseded v2 provider-specific Worker binaries for
migration/reference work. They are not the v8 local execution path; do not use
them to add or update a normal provider integration.

Use the repository scripts from the project root to build a debug Workspace
and unsigned native Worker packages for the current OS/CPU. Local packages are
tagged `local-development`, use the `development` channel, and are accepted
only by a debug Workspace built with the explicit development flag. They do
not use or modify Cloud release records or signing roots.

```sh
# Build both Worker binaries and the debug Workspace app.
bash scripts/build-all-desktop-apps.sh

# Build either Worker separately or build both.
bash scripts/build-chatgpt-worker.sh
bash scripts/build-gemini-worker.sh
bash scripts/build-workers.sh --worker all --version 0.0.0-dev.1

# Install into this user's normal Workspace Worker version store.
bash scripts/install-development-workers.sh --worker all
```

Other entry points are `scripts/build-workspace.sh` and the pnpm aliases
`worker:build`, `worker:build:chatgpt`, `worker:build:gemini`,
`worker:install:dev`, `workspace:build`, and `desktop:build`. The default
development Workspace build is debug and enables the unsigned local marker;
`--release` never enables it. Worker artifacts are written under
`dist/workers/<platform>/<workerTypeId>/` and remain outside the app bundle.

The installer applies digest, protocol, permission, executable identity, and
passive-probe checks before activation. Use `--no-activate` to stage without
switching the active version. The Workspace Worker row can then run a passive
or explicit live probe against that version. A live probe can consume provider
allowance. Current assignment routing still uses the legacy executor, so this
flow validates native installation and probing but does not yet route Cloud
assignments through the Dart executable.

Each version directory is immutable. Bump `--version` (or let the default dev
version timestamp change) for each rebuild before installing over an existing
development version.


## Architecture v8 operational target

Do not publish a new provider-specific native Worker release for a normal CLI integration. Provider behavior changes should normally be released as signed Tool Profile revisions. Native binary publication is reserved for Workspace or generic Engine changes.
