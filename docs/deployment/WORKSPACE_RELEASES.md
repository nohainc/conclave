# Workspace and Adapter Release Operations

## Adapter releases

The manually dispatched [V7 adapter release workflow](../../.github/workflows/release-v7-adapter.yml)
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
- `CONCLAVE_RELEASE_PUBLISH_TOKEN` secret and `CLOUD_API_URL` variable;
- `CONCLAVE_RELEASE_TRUST_KEYS_JSON` variable containing public roots.

Use `scripts/build-workspace-macos.sh` for a local build. A local build may be
unsigned and is not production release evidence. Apple signing/notarization is
complementary to Conclave's signed release metadata.

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
