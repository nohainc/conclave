# Workspace, Engine, and Tool Profile Release Operations

**Architecture v8:** the active target uses one generic CLI Worker Engine plus
signed Tool Profile releases. Per-provider native ChatGPT/Gemini Worker
releases documented later in this file are migration history until removed.

## v8 release classes

Conclave now has three distinct release classes:

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

Profile rollback selects a previous trusted compatible release. Revoked releases
are never eligible for activation/rollback.

### Generic Engine release flow

The first v8 implementation may ship a known-good Engine with Workspace. The
Engine still has its own version and diagnostic identity. If independent Engine
delivery is enabled later, it must use immutable signed platform artifacts,
active/LKG state, admission, health check, and rollback.


**Current Worker release contract:** signed platform-specific native Dart
executables published as Worker release v2 records. The Node adapter workflow
and adapter signing configuration below are retained as migration history only.
Workspace release and Worker release are separate pipelines and trust classes.

## Legacy adapter release tooling

The manually dispatched [V7 adapter release workflow](../../.github/workflows/release-v7-adapter.yml)
is retained only as migration tooling. Its releases are no longer part of the
Cloud catalog. Migration `0035_worker_releases.sql` drops
`v7_adapter_releases`; pre-production release rows are recreated through the
native Worker publish workflow.

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

## Historical v2 native provider Worker release catalog

Cloud stores immutable releases in `worker_releases`, keyed by Worker Type ID,
version, and platform. The catalog requires a platform and can be narrowed by
Worker Type ID and channel:

```text
GET /api/worker-releases?platform=macos-arm64&workerTypeId=chatgpt&channel=stable
POST /api/worker-releases/publish
GET /api/worker-releases/{workerTypeId}/{version}/{platform}/download
POST /api/worker-releases/{workerTypeId}/{version}/{platform}/revoke
GET /api/worker-releases/trust
```

Publishing verifies the Worker Release Manifest v2 signature and archive hash
before writing the platform artifact to R2. A release identity cannot be
overwritten. Revocation applies to one platform artifact; signing-key
revocation remains available through the Worker release trust endpoint.

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

## Historical Worker Runtime v2 release workflow

ADR-017 defines independently versioned platform-specific native Worker releases. Node adapter release tooling remains migration-only; first-party Worker releases are native Dart executables. The native publish workflow is implemented, but full Workspace download, admission, candidate activation, update/rollback, and assignment-path acceptance remain tracked gates.

Target Worker release flow:

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

### Publishing native ChatGPT and Gemini Workers

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

### Local unsigned Worker development

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
