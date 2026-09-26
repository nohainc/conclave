# Conclave Workspace

Conclave Workspace is the machine-side execution and security runtime.

It maintains the Cloud connection, owns the local Work Root, creates/resolves
Workstream working directories, manages locally configured Workers and their
credentials, installs/verifies Worker Type adapter packages, launches adapter
child processes, enforces local permissions, supervises execution, and reports
safe readiness/status back to Conclave Cloud.

Its GUI is intentionally minimal and local-first:
- pairing/connection;
- Workers;
- provider authentication;
- local permissions;
- current local work;
- diagnostics/logs;
- updates;
- pause/quit.

Projects, Workstreams, Discuss, Work orchestration, Project membership and
remote scheduling policy belong in Conclave AX.

Users install only Conclave Workspace. Worker adapters are managed internally;
they are not separately installed desktop applications.

## Packaging a V7 adapter release

Use `.github/workflows/release-v7-adapter.yml` for development, beta, stable,
and revocation operations. Its Ed25519 private seed is a protected GitHub
environment secret. The packager computes the file-tree digest and signs the
canonical manifest and digest. Workspace receives only public trust roots.

```sh
cd apps/host
CONCLAVE_RELEASE_SIGNING_SEED="$V7_ADAPTER_ED25519_SEED" \
CONCLAVE_RELEASE_SIGNING_KEY_ID="adapter-2026-01" \
  dart run bin/package_v7_adapter.dart \
  --source ../../packages/worker-manifest/adapters/codex \
  --output ../../dist/codex-1.0.0.tgz \
  --channel development
```

Never copy private seeds to Workspace or desktop builds. Configure the public-
only `CONCLAVE_RELEASE_TRUST_KEYS_JSON` build define with publisher/key IDs and
base64 raw Ed25519 public keys. Use distinct adapter and Workspace key IDs and
rotate them independently; ship overlapping public keys during rotation.
Workspace refreshes key and release revocations, blocks new assignments for a
revoked adapter, and lets active work finish before replacing it.

Workspace update metadata is signed by an independent Ed25519 application
release key and binds the archive digest, version, channel, supported platform,
minimum supported version, and release notes. macOS Developer ID signing and
notarization complement this verification; they do not replace it. Publish
macOS builds through `.github/workflows/release-workspace-macos.yml`; it checks
the downloaded release metadata signature and archive digest.

Before enabling either workflow, configure `CONCLAVE_RELEASE_TRUST_KEYS_JSON`
as a public Cloud Worker variable and as a GitHub environment variable. It must
contain the same raw public keys embedded into Workspace builds. The release
environments also require `CLOUD_API_URL`, `CONCLAVE_RELEASE_PUBLISH_TOKEN`,
`CONCLAVE_ADAPTER_ED25519_SEED`, `CONCLAVE_ADAPTER_SIGNING_KEY_ID`,
`CONCLAVE_WORKSPACE_ED25519_SEED`, and
`CONCLAVE_WORKSPACE_SIGNING_KEY_ID`. Keep the two private seeds separate.
The macOS environment additionally needs the Developer ID certificate and
Apple notarization credentials used by its workflow. Workflows fail closed
when required keys or credentials are absent.

## Desktop development and macOS build

Conclave Workspace is the native desktop product. The Flutter GUI and the
headless entrypoint share the same runtime composition in
`lib/workspace_runtime.dart`.

The current macOS release target requires macOS 12 or newer.

Build a macOS release package from repository root:

~~~text
bash scripts/build-workspace-macos.sh
~~~

Optional release environment:
- `CONCLAVE_MACOS_SIGN_IDENTITY` — Developer ID Application identity;
- `CONCLAVE_MACOS_NOTARY_PROFILE` — `notarytool` keychain profile;
- `CONCLAVE_WORKSPACE_VERSION` — override build version.
- `CONCLAVE_RELEASE_TRUST_KEYS_JSON` — public Ed25519 roots; an empty value
  intentionally trusts no release signer.

The output ZIP is written under `dist/conclave-workspace/macos`.

## Pairing

In Conclave AX web:
1. create/open a Workspace;
2. choose **Connect machine**;
3. copy the one-time code.

In Conclave Workspace desktop:
1. choose **Start pairing**;
2. paste the code;
3. keep the production Cloud URL unless using local/staging;
4. pair.

The one-time code is exchanged for a Workspace Runtime ID and bearer token.
The token is stored only in the platform secure credential store.

To verify a real Cloud connection with a disposable Workspace:

~~~text
CONCLAVE_ENROLLMENT_TOKEN='conclave_enroll_...' \
  bash scripts/test-workspace-cloud-connection.sh
~~~

## Worker naming

- **Codex** Worker Type invokes Codex CLI; authentication may be a ChatGPT account.
- **Antigravity** Worker Type invokes the `agy` CLI; authentication may be a Google account.
- **Claude Code** invokes the locally authenticated `claude` CLI in headless mode. The CLI session is validated locally, and the adapter inherits the active Workstream directory.
- **Ollama** connects to the configured local service, checks its version and installed models, and runs the selected model without storing a provider credential.
- **OpenAI API**, **Gemini API**, and **Anthropic API** are direct API Worker Types.

API Workers validate locally stored credentials against provider model-list
endpoints where available; the setup flow exposes returned model IDs for
selection. Claude Code and Ollama adapter packages are installed only from
trusted, signed catalog releases. Their protocol, mock-service and signed
package admission tests run with `pnpm worker-adapters:test` and the Host adapter
package tests.

Worker Type names describe the integration Conclave invokes, not the model or
subscription brand.
