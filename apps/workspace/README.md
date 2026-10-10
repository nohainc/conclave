# Conclave Workspace

Development launchers now exercise signed Cloud Profile releases by default,
with public roots matching the independent development signer. Start
`bash scripts/run-workspace-development.sh` for localhost, or set
`CONCLAVE_DEVELOPMENT_CLOUD_URL=https://app.conclaveax.com` for the provisioned
hosted development deployment. Assign the Workspace to Testing in Profile Lab
after publishing the qualified Draft. Desktop signing does not change this flow.
The unsigned Draft shortcut remains an explicit, non-release, loopback-only opt-in
through `CONCLAVE_DEVELOPMENT_PROFILE_DIRECTORY`; it does not test Cloud rollout.

Conclave Workspace is the machine-side execution and security runtime.

It maintains the Cloud connection, owns application-managed runtime state,
resolves the user-owned local Work Root, and creates/resolves one stable
working directory per Space shared by its Threads, manages logical Workers and local provider
credentials, resolves signed Tool Profiles, launches the generic CLI Worker
Engine, enforces local permissions, supervises execution, and reports safe
readiness/status back to Conclave Cloud.

Its GUI is intentionally minimal and local-first:
- account sign-in and explicit service start/stop;
- Workers;
- provider authentication;
- local permissions;
- service health and Cloud connection status;
- diagnostics/logs;
- updates;
- pause/quit.

Spaces, Threads, Discuss, Work orchestration, Space membership and
remote scheduling policy belong in Conclave AX.

The authoritative ownership and lifecycle contract is the
[Workspace architecture](../../docs/architecture/WORKSPACE_ARCHITECTURE.md).

The Workspace is an execution environment, not a directory. Its private
Application Data Root is resolved automatically under the Conclave application
family root (`~/Library/Application Support/Conclave/Workspace/` on macOS).
The user Work Root is separate and defaults to `~/Documents/Conclave`; Space
Work Directories live beneath it.
Space directory names are human-readable, while a private registry and marker
bind each directory to its immutable Space ID. Thread directories are not
created during normal execution; Thread sessions and runtime metadata remain
under Application Data Root.

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

## Headless Workspace service

The Workspace runtime has a standalone Dart service entry point at
`bin/conclave_workspace_service.dart`. It uses the existing Cloud and local
Worker protocols and does not import Flutter APIs. Build it with
`bash scripts/build-workspace-service.sh`; the resulting executable and its
generic CLI Worker Engine are placed under `dist/conclave-workspace/service/`.
The build injects `CONCLAVE_RELEASE_TRUST_KEYS_JSON` into the service as well
as the Flutter app, so the service can verify and use signed Tool Profiles.
The service can be run without starting the Flutter application and maintains
separate process, Cloud-connection, and execution state in
`workspace-state.json`.

The service exposes a versioned, authenticated local IPC protocol for status,
connection, Worker, assignment, configuration, log, and diagnostics commands.
Service restart and shutdown remain host-manager operations. The Flutter
management shell connects through this protocol and does not create or control
an in-process execution runtime. See the canonical architecture document for
the command surface, ownership map, and validation gates.

For development, first run `scripts/build-workspace-service.sh`, then
`scripts/run-workspace-service.sh` starts the compiled `conclave-service`
against the existing local configuration without building the Flutter app.
Use `scripts/run-workspace-service.sh --source` only when debugging Dart source
directly; that mode intentionally appears as a Dart VM process.
Compiled service and Engine processes set their macOS diagnostic names at
startup, so Activity Monitor shows `conclave-service` and `conclave-agent`
instead of the Dart runtime prefix. This changes only the local display name;
IPC, Workspace credentials, and Cloud authentication are unchanged.
`scripts/check-workspace-service.sh` compiles it and runs a one-shot lifecycle
in temporary directories; the Workspace CI validation invokes the same check.
The per-installation lock rejects a second service process that attempts to
own the same Workspace installation.

## Desktop development and macOS build

Conclave Workspace is the native desktop product. The headless service composes
the runtime in `lib/workspace_runtime.dart`; the Flutter GUI manages it over
local IPC.

The current macOS release target requires macOS 12 or newer.

The package embeds the standalone service helper, its generic Engine, and an
`SMAppService` LaunchAgent manifest. Background registration requires macOS 13
or newer. Persistent execution through the managed service requires macOS 13
or newer; earlier macOS versions can open the management UI but cannot start
the service. See the canonical architecture document for the bundle contract,
status semantics, and signed-device validation requirements.

Build a local macOS Workspace app from repository root:

~~~text
bash scripts/build-workspace-macos.sh
~~~

The local build bundles the generic CLI Worker Engine. With no arguments the
script creates a signed release using the configured local Apple Development
identity. Use `--sign` or `CONCLAVE_MACOS_SIGN_IDENTITY` to select another
certificate. The build signs the embedded Flutter frameworks, service helper,
and Worker Engine with the same identity, preserves the helper entitlements,
and verifies all three before packaging. macOS rejects ad-hoc signed helpers
launched through SMAppService before the service can create its IPC socket;
restore the signing certificate and private key if that check fails.
`--debug` without an identity is available for UI inspection only; Start Service
reports the signing requirement immediately. Install a valid signing certificate
and its private key in Keychain before building a service-enabled app.

Optional environment:
- `CONCLAVE_MACOS_SIGN_IDENTITY` — optional signing identity override;
- `CONCLAVE_MACOS_NOTARY_PROFILE` — `notarytool` keychain profile;
- `CONCLAVE_WORKSPACE_VERSION` — override build version.
- `CONCLAVE_RELEASE_TRUST_KEYS_JSON` — explicit public Ed25519 roots. Unsigned
  builds otherwise reuse `.development/hosted-profile-trust.json`. Missing,
  empty, or invalid roots fail the build; Developer ID signed builds require
  explicit roots and never automatically adopt development keys.

The output ZIP is written under `dist/conclave-workspace/macos`.

## Account and Workspace lifecycle

The desktop path uses browser-based Better Auth sign-in, followed by
**Start Service**. Starting registers or recovers the existing installation,
enables the embedded per-user LaunchAgent, and waits for authenticated local
IPC. The service independently connects to Cloud using WebSocket with HTTP
fallback and bounded reconnect backoff. A running service can therefore be
Cloud-offline without being stopped.

**Stop Service** asks the service to stop accepting work and drain active
assignments before terminating the process. If work does not finish within the
bounded grace period, stopping is refused and admission resumes. Stopping
does not unregister the LaunchAgent or change the persisted Cloud connection
intent. Closing or quitting Workspace.app only closes the management client
and leaves the service running.

The two tabs are **Workspace** and **Workers**. Worker configuration and live
tests execute in the service through authenticated IPC; the UI awaits results.
A local display cache retains the last known Worker list while the service is
stopped, with configuration and tests disabled. Name and Work Root are editable
only while the service is stopped. Diagnostics and actionable service/Cloud
errors remain accessible from the Workspace tab.

Packaged runtime process names are `conclave-service` and `conclave-agent`.
The latter is the separately isolated generic CLI Worker Engine, materialized
under the existing Workspace Engine registry. LaunchAgent identity remains
`com.conclaveax.workspace.service`; assets retain their shared Engine names.
An independently installed legacy `conclave_agent_engine` daemon is outside
this bundle and is not silently stopped or removed by the manager.

Workspace error and warning messages include a copy action where they are
shown, including transient notifications and Worker setup details. Copying a
message copies its displayed text; it does not extend the message's existing
display timeout.

Stopping the service preserves installation ownership and local Worker/provider
credentials. Release ownership is a separate advanced action for a stopped
Workspace and permits a different account to connect. Reset local Workspace
has separate published data-removal semantics; see [ADR-014](../../docs/decisions/ADR-014-workspace-desktop-lifecycle.md).

## Cloud connection

Sign in to Conclave Workspace with browser-assisted desktop authentication.
Workspace verifies installation ownership, registers or recovers through
`POST /api/workspace-runtime/register`, and then connects to the Workspace
Gateway using its runtime credential. Disconnect and ownership release use the
desktop human session.

The service journals assignment outcomes and classifies interrupted work on
startup before accepting new work. See the canonical architecture document for
recovery states, process cleanup, logging, and current Cloud reconciliation
limits.

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

## Work Root configuration before startup

Work Root is a machine-local setting in `workspace-lifecycle.json` under
Application Data. Workspace.app validates and saves it while the service is
stopped, without IPC or Cloud access; service startup reads the same file.
The installation's advisory lock protects against edits while an independent
service process is running even if its IPC socket is unavailable. A changed
root applies to future Space directory resolution and never moves existing
user files. The running-service API rejects Work Root changes.

Before starting or restarting the background service, Workspace.app performs a
write-access preflight against the configured Work Root. If macOS has not yet
granted the application access to that folder, the app opens the native folder
permission flow while the UI is available. The service is started only after
the preflight succeeds, so the first Worker request does not need to trigger
the initial folder-access prompt from a headless process.

Start Service first attempts IPC attachment. If macOS has an enabled but stopped
job (including an old helper path after an update), the native bridge refreshes
its `SMAppService` registration. It does not unregister a running job. Local
IPC and configuration reload become ready before Cloud's initial handshake;
Cloud failure is shown as connectivity state, not local startup failure.

## Service startup diagnostics

Failed initial IPC attempts are disposed (subscription and client), so retries
read the current capability key and socket instead of retaining a failed
client. Concurrent startup calls share one in-flight attempt; an established
client keeps event-driven reconnect behavior. A registration timeout reports
that IPC attachment failed, not that the process necessarily failed to start.
The error and Advanced Diagnostics include registration, launchd state, key/
socket presence, last IPC error, and the last service exit code when available.
The native bridge exposes selected operational fields only, never the launchd
environment or the local capability key. IPC remains independent of Cloud
connectivity. Login/reboot, TCC and signed-device acceptance remain separate
release checks.
