# Workspace architecture

This is the canonical description of the Workspace application and runtime.
The phase documents in this directory record historical implementation work;
new code should follow this document.

## Ownership

```text
Conclave Workspace.app
    management UI, account/setup forms, native service controls, IPC client
                 │
                 ├── macOS host manager
                 │     register/start/stop/restart/unregister and process facts
                 │
                 └── authenticated local IPC
                              │
                    Conclave Workspace Service
                    Cloud transport, assignments, state, workers, sessions,
                    logs, diagnostics, and Work Root access
                              │
                         Worker subsystem
                         registry, catalog, profiles, readiness, supervision
                              │
                       generic CLI Worker Engine
                              │
                       signed Tool Profile → provider CLI
```

Workspace.app must not create a Cloud connection, run readiness checks, spawn
the Worker Engine, or execute an assignment. It may display a cached snapshot,
but the Service is authoritative. The Worker Engine is an execution primitive;
it receives a profile, command, environment policy, working directory, input,
execution options, and cancellation, and returns output. It has no Cloud,
Space, Thread, Workflow, D1, or UI dependency.

The service is a standalone Dart executable (`conclave-service`) and keeps the
generic Engine as a separately supervised child (`conclave-agent`). The service
holds the per-installation lock, owns process cleanup, and is the only runtime
owner. Closing Workspace.app closes its IPC client and does not stop execution.
At startup the compiled Dart processes set their macOS diagnostic names to
those product names. This affects only Activity Monitor/process diagnostics;
it does not change the executable, IPC protocol, Workspace credentials, or
Cloud authentication.

## Lifecycle and state

Host registration and process state are separate from Cloud state:

```text
Service: registered → stopped | starting → running | failed
Cloud:   disconnected | connecting | connected | reconnecting
```

`Stop Service` drains/cancels according to the bounded service policy,
disconnects Cloud, terminates child Engines, and leaves host registration in
place. `Unregister Service` is a separate destructive host operation. Starting
the service does not implicitly request a Cloud connection; persisted Cloud
intent is restored by the service after it starts. All runtime commands
(`connection.*`, `worker.*`, assignment controls, configuration, logs, and
diagnostics) cross authenticated versioned IPC. Host operations cannot be
implemented through IPC because they must start or stop a process that may not
exist.

The service persists enough assignment and process information to reconcile a
restart without blindly rerunning uncertain work. Cloud session history is
audited in D1, while live transport state, queues, cursors, and acknowledgments
belong to the Cloud gateway's live transport layer.

## Worker subsystem

`WorkspaceWorkerSubsystem` is the service composition boundary. It owns the
local Worker registry, catalog/profile resolution, capability-aware readiness,
Engine supervision, and the small API used by runtime and IPC:

```text
listWorkers · enableWorker · disableWorker · testWorker · resolveWorker
refresh · execute · cancel · recoverOrphanedProcesses · shutdown
```

Worker lifecycle (`absent`, `installing`, `ready`, `degraded`, `failed`,
`removing`) is separate from activation (`enabled` or `disabled`). A Worker
Engine process is started on demand for a probe or assignment and is always
tracked by the one process supervisor. No UI polling loop or idle Engine is
required.

## Local IPC

The manager protocol is versioned, authenticated with a per-installation
capability key, and transported over a private Unix-domain socket on macOS.
The service sends an initial status snapshot and then event updates. Clients
must negotiate the protocol version, authenticate before commands, bound frame
sizes, and reconnect with backoff. The socket is a management boundary, not a
public localhost API.

## Filesystem ownership

Conclave-owned runtime state is under:

```text
~/Library/Application Support/Conclave/Workspace/
    configuration, registry, profiles, engines, sessions, assignments,
    logs, cache, runtime
```

User-owned files are under the configured Work Root (default
`~/Documents/Conclave`) and Space directories below it. A Worker receives the
resolved Space directory, never Application Support as its normal working
directory. Resetting runtime state, clearing logs/cache, deleting a Thread, or
removing a Workspace must not delete user work. Space directory identity is
stable and tied to `spaceId`; display-name changes do not silently move files.

## Authentication and security

The service reads the existing Workspace registration and secure runtime
credential; it does not create a replacement Cloud identity. Cloud HTTP and
WebSocket paths use the same `WorkspaceRuntimeAuthenticator`. The service
never places tokens in application tables or forwards Cloud credentials to a
Worker Engine. IPC authorization, installation ownership, execution admission,
and Work Root boundaries are enforced by the service.

## Configuration sources

Persisted registration, lifecycle preferences, secure credentials, Worker
registry, Profiles, sessions, and Work Root are authoritative for a normal
service installation. Environment variables are explicit build/development
inputs or temporary command-line overrides; a LaunchAgent must not depend on a
shell profile or hidden environment fallback.

| Variable | Classification | Purpose |
| --- | --- | --- |
| `CONCLAVE_WORKSPACE_VERSION` | build/release | UI and service version |
| `CONCLAVE_RELEASE_TRUST_KEYS_JSON` | build/release | public Tool Profile trust roots |
| `CONCLAVE_MACOS_SIGN_IDENTITY` | build/release | application/service signing |
| `CONCLAVE_MACOS_NOTARY_PROFILE` | release-only | notarization keychain profile |
| `CONCLAVE_DART_EXECUTABLE` | build/test-only | select a Dart SDK for Engine builds |
| `CONCLAVE_DEVELOPMENT_CLOUD_URL` | development-only | loopback Cloud origin for dev runner |
| `CONCLAVE_DEVELOPMENT_PROFILE_DIRECTORY` | development-only | unsigned local Profile drafts |
| `CONCLAVE_WORKSPACE_DEVELOPMENT_DATA_DIR` | development-only | isolated dev state root |
| `CONCLAVE_WORKSPACE_BUNDLE_DIR` | test/development-only | explicit bundled Engine location |
| `CONCLAVE_WORKSPACE_DATA_DIR` | CLI/test override | explicit state directory; persisted state wins in packaged service |
| `CONCLAVE_WORKSPACE_CLOUD_URL` | CLI/test override | explicit Cloud origin before registration exists |
| `CONCLAVE_WORKSPACE_WORK_ROOT` | CLI/test override | explicit Work Root before preferences exist |
| `CONCLAVE_WORKSPACE_RUNTIME_ID`, `CONCLAVE_WORKSPACE_INSTALLATION_ID`, `CONCLAVE_WORKSPACE_ID` | CLI/test override | fixture identity values; never production secrets |
| `CONCLAVE_WORKSPACE_TOKEN` | test-only | fixture credential; production uses secure storage |

`CONCLAVE_WORKSPACE_GATEWAY` is a Cloudflare binding name, not Workspace
configuration. Provider, profile-admin, deployment, and database variables are
owned by their respective Cloud/Profile Lab workflows and are outside this
runtime contract.

## Build and artifact pipeline

There is one Worker Engine source and build:

```text
engines/cli_worker
       ↓ scripts/build-cli-worker-engine.sh
apps/workspace/assets/engines/conclave_cli_worker_engine
apps/profile_lab/assets/engines/conclave_cli_worker_engine
```

The two app paths are materialized copies for their bundles, not independent
source artifacts. `scripts/build-workspace.sh` is the cross-platform entry
point; `scripts/build-workspace-macos.sh` assembles the signed macOS app and
LaunchAgent; `scripts/build-workspace-service.sh` builds the standalone service
for focused development; `scripts/run-workspace-service.sh` launches that
compiled executable by default and reserves `--source` for Dart debugging;
`scripts/check-workspace-service.sh` and
`scripts/verify-workspace-service-bundle.sh` validate the service package.
Signing and launchd checks are release/device evidence and cannot be replaced
by a successful Dart compile.

## Validation and boundaries

Focused suites are organized around the ownership model:

| Suite | Protects |
| --- | --- |
| Workspace UI | management screens and IPC projections |
| Workspace Service/runtime | lifecycle, assignment recovery, configuration, filesystems |
| Workspace IPC | authentication, versioning, commands, events |
| Worker Engine | profile/command execution and process cleanup |
| Workspace Cloud | runtime authentication, sessions, inventory, admission |
| Workspace DB | schema and migration contracts |

Architecture tests assert that the UI does not construct Cloud/Engine runtime
objects or spawn processes, the Engine does not import Cloud domain code, the
Service composes Cloud and Workers, `Stop Service` does not unregister, and
`Disconnect Cloud` leaves the service process available. Historical migration
tests remain where they protect existing installations; obsolete architecture
tests should be removed only after an equivalent boundary test exists.

## Future portability

The shared service and protocol remain platform-independent Dart. macOS host
registration is behind `WorkspaceServiceManager`; Windows and Linux adapters
(SCM/systemd, named pipes/Unix sockets, and platform secret stores) are future
work and are not part of this implementation.
