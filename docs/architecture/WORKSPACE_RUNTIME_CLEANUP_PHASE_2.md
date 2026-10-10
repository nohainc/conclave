# Workspace Runtime Cleanup — Phase 2

> **Historical implementation record.** The current architecture is defined
> in [WORKSPACE_ARCHITECTURE.md](WORKSPACE_ARCHITECTURE.md).

Phase 2 establishes the Worker boundary inside the Workspace Service.

## Vocabulary

- **Worker** — a user-configured execution slot in a Workspace.
- **Worker Type** — the catalog identity of an approved integration, such as
  `chatgpt` or `gemini`.
- **Tool Profile** — signed, provider-neutral instructions describing the CLI
  integration.
- **Worker Engine** — the generic executable that runs a Tool Profile.
- **Provider CLI** — the external CLI launched by the Worker Engine.

Readiness and activation are separate. A Worker can be enabled while its
current Profile, CLI, or credentials are unavailable. The canonical local
readiness states are `not_probed`, `ready`, `setup_required`,
`sign_in_required`, `worker_runtime_unavailable`, and `test_failed`. Activation
is independently `enabled` or `disabled`.

## Service-owned Worker subsystem

`WorkspaceWorkerSubsystem` is the composition boundary for local Worker
management. It owns the registry, catalog/Profile synchronization, readiness
monitor, assignment handler, and generic Engine process supervisor. The
Workspace Service exposes the small operations needed by its IPC manager:

```text
listWorkers
resolveWorker
enableWorker
disableWorker
testWorker
execute
cancel
refresh
refreshReadiness
ensureProfile
reset
rollbackProfile
cancelAssignment
```

The Flutter Workspace application does not access these components directly.
It sends typed manager commands to the Service, which delegates through this
boundary.

## Execution and protocol ownership

The execution path is:

```text
AX/Cloud domain
    ↓
Workspace Runtime Protocol
    ↓
Workspace Service
    ↓
Worker subsystem
    ↓
Worker Protocol
    ↓
Worker Engine
    ↓
Provider CLI
```

Worker Engine messages contain execution inputs, Profile and environment
policy, working directory, cancellation and output data. They do not contain
Cloud, Space, Thread, workflow, membership, D1, or AX UI state. Cloud-facing
assignment admission remains a Service concern before an execution request is
sent to the Engine.

The Engine supervisor is the single process boundary for Engine lifecycle,
PID recovery, cancellation and shutdown. Direct provider CLI process launches
remain inside the lower-level CLI runners used by the Engine; Workspace code
must not spawn Worker Engine processes outside the supervisor.

Cloud catalog statuses and Profile release versions are separate concerns from
the local Worker lifecycle. Compatibility fields are retained only where they
are part of an existing wire contract and are not used as local readiness
aliases.
