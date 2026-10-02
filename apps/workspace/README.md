# Conclave Workspace

Conclave Workspace is the machine-side execution and security runtime.

It maintains the Cloud connection, owns the local Work Root, creates/resolves
Workstream working directories, manages logical Workers and local provider
credentials, resolves signed Tool Profiles, launches the generic CLI Worker
Engine, enforces local permissions, supervises execution, and reports safe
readiness/status back to Conclave Cloud.

Its GUI is intentionally minimal and local-first:
- account sign-in and explicit Workspace connection/lifecycle;
- Workers;
- provider authentication;
- local permissions;
- current local work;
- diagnostics/logs;
- updates;
- pause/quit.

Projects, Workstreams, Discuss, Work orchestration, Project membership and
remote scheduling policy belong in Conclave AX.

Users install only Conclave Workspace. Workspace manages the bundled generic
Engine and signed Tool Profile releases; provider CLI software is installed
separately by its provider.

Workspace update metadata is signed by an independent Ed25519 application
release key and binds the archive digest, version, channel, supported platform,
minimum supported version, and release notes. macOS Developer ID signing and
notarization complement this verification; they do not replace it. Publish
macOS builds through `.github/workflows/release-workspace-macos.yml`. The
workflow requires a successful repository CI run for the selected `main`
revision before it builds or publishes, then checks the downloaded release
metadata signature and archive digest.

The Workspace release workflow uses the Workspace signing key and public trust
roots. The generic Engine is bundled with Workspace; provider-specific Worker
package signing and publishing workflows have been retired.

## Desktop development and macOS build

Conclave Workspace is the native desktop product. The Flutter GUI and the
headless entrypoint share the same runtime composition in
`lib/workspace_runtime.dart`.

The current macOS release target requires macOS 12 or newer.

Build a local macOS Workspace app from repository root:

~~~text
bash scripts/build-workspace-macos.sh
~~~

The local build bundles the generic CLI Worker Engine. Apple Developer ID
signing is separately optional via `--sign`.

Optional environment:
- `CONCLAVE_MACOS_SIGN_IDENTITY` — Developer ID Application identity;
- `CONCLAVE_MACOS_NOTARY_PROFILE` — `notarytool` keychain profile;
- `CONCLAVE_WORKSPACE_VERSION` — override build version.
- `CONCLAVE_RELEASE_TRUST_KEYS_JSON` — public Ed25519 roots; an empty value
  intentionally trusts no release signer.

The output ZIP is written under `dist/conclave-workspace/macos`.

## Account and Workspace lifecycle

The normal desktop path uses browser-based Better Auth sign-in, followed by an
explicit **Connect Workspace** action. Sign-in alone does not register or start
the runtime. Connect sends the persistent installation ID and safe machine
facts, then recovers or creates the Workspace for the authenticated owner.
Human session, runtime credential, and local Worker/provider credentials are
separate secrets stored in their respective secure stores.

Connected Workspaces can start at macOS login through `SMAppService.mainApp`.
The preference is offered during first Connect and can later be changed in the
Workspace Account section. Startup uses the runtime credential and persisted
desired-runtime state; it does not require interactive human sign-in. A
deliberately disconnected Workspace stays disconnected after restart. Closing
the window leaves the runtime running. Locking protects management UI without
stopping runtime work.

Workspace error and warning messages include a copy action where they are
shown, including transient notifications and Worker setup details. Copying a
message copies its displayed text; it does not extend the message's existing
display timeout.

Disconnect preserves installation ownership and local Worker/provider
credentials. Release ownership is a separate advanced action for a disconnected
Workspace and permits a different account to connect. Reset local Workspace
has separate published data-removal semantics; see [ADR-014](../../docs/decisions/ADR-014-workspace-desktop-lifecycle.md).

## Cloud connection

Sign in to Conclave Workspace with browser-assisted desktop authentication.
Workspace verifies installation ownership, registers or recovers through
`POST /api/workspace-runtime/register`, and then connects to the Workspace
Gateway using its runtime credential. Disconnect and ownership release use the
desktop human session.

## First-party Worker v1 contract

The supported product-facing Worker slots are **ChatGPT**, powered by Codex
CLI (`codex`), and **Gemini**, powered by Antigravity CLI (`agy`). Each
Workspace has one local Worker slot for each logical Worker Type. The
corresponding CLI owns sign-in, credential storage, and billing
mode; Conclave checks whether the CLI can execute and does not request or store
provider credentials. See [ADR-015](../../docs/decisions/ADR-015-first-party-worker-v1-contract.md).

The native ChatGPT and Gemini Worker source packages remain pending the real
Engine/Profile acceptance gate, but their build/install/release tooling is
retired. Normal Workspace execution uses the generic Engine and signed Tool
Profiles. Worker readiness remains a local execution fact; Cloud receives only
safe inventory.
