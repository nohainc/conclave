# Workspace and Worker Release Operations

## Current adapter releases (migration-only)

The current manually dispatched [V7 adapter release workflow](../../.github/workflows/release-v7-adapter.yml)
supports `development`, `beta`, and `stable` channels and immutable release
revocation. A publish run installs locked dependencies, runs adapter
protocol/provider-mock tests and Workspace admission tests, packages
deterministically, signs with the adapter Ed25519 key, publishes to Cloud/R2,
downloads the catalog artifact, checks its digest, and runs normal Workspace
release verification.

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

Use the adapter's declared version and platform support; never overwrite a
published version. Promote by publishing a new immutable record for the
appropriate channel after verification. To revoke, dispatch `action: revoke`
with the Worker Type ID, exact version, and reason. Revocation prevents future
admission; it does not terminate active adapter processes.

The test command for local protocol/provider-mock coverage is:

```sh
pnpm worker-adapters:test
```

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
  `CONCLAVE_ADAPTER_SIGNING_KEY_ID` variable; the configured public trust roots
  must include this adapter key;
- `CONCLAVE_RELEASE_PUBLISH_TOKEN` secret and `CLOUD_API_URL` variable;
- `CONCLAVE_RELEASE_TRUST_KEYS_JSON` variable containing public roots.

The build packages stable Codex and Antigravity adapters with the protected
adapter signing key, verifies both archives against the configured public
trust roots, and embeds them as app assets. Generated package archives and
manifests are build outputs and are not committed. By default,
`scripts/build-workspace-macos.sh` makes a local build with unsigned bundled
first-party adapters. That build accepts unsigned code only for embedded
ChatGPT/Gemini adapters; Cloud-delivered adapters remain signature-verified.
Use `--sign-adapters` with the protected adapter signing configuration for a
product release. Apple app signing/notarization is separate from adapter
package signing and Conclave's signed release metadata. A local build is not
production release evidence.

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

## Worker Runtime v2 release target

ADR-017 replaces the first-party adapter release path with independently versioned platform-specific native Worker releases. The current Node adapter workflow remains migration tooling only until the Dart ChatGPT/Gemini Workers pass real acceptance.

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
