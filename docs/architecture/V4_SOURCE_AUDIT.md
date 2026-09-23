# Architecture v4 Source Audit

**Repository reviewed:** `nohainc/conclave`  
**Baseline:** main at the Architecture v4 design pass  
**Purpose:** Map current v3 sources to the simplified Host + Worker model.

## 1. Executive assessment

The current code is already strong in several areas:
- Cloud-first authority;
- Goal/Run/Task/Attempt domain;
- schema-first TS/Dart protocols;
- Dart process supervision;
- signed package installation;
- secure credential primitives;
- one clean D1 development baseline;
- Cloudflare Agent Gateway;
- WorkerAssignment persistence;
- chat-first Studio direction;
- multi-worker policies;
- first-party Dart integration packages.

The largest remaining complexity is conceptual duplication:

```text
Agent App
Agent Engine
Agent
Plugin
configured Worker
Plugin install
Connection/credential concepts
```

v4 collapses that to:

```text
Host
Worker
Credential Profile
Assignment
```

## 2. Current -> v4 mapping

| Current source/concept | v4 action |
| --- | --- |
| `apps/studio` | Web-only Studio application |
| `apps/worker` | Keep; rename to `apps/cloud` |
| `apps/agent_app` | Merged into `apps/host` |
| `apps/agent_engine` | Merged into `apps/host`; IPC/process split removed |
| `workers/*` | Keep Worker package implementations |
| `packages/agent-protocol` | Replace/merge into Host protocol |
| `packages/plugin-manifest` | Rename to `packages/worker-manifest` |
| `packages/dart/worker_protocol` | Canonical Worker JSON-RPC protocol |
| Agent Gateway | Rename/refactor to Host Gateway |
| Agent entities/tables | Replace with Host entities/tables |
| WorkerPlugin entities/tables | Replace with Worker catalog/version |
| configured `Worker` entity/table | Delete |
| `agent_plugin_installs` | Replace with `host_worker_installations` |
| `WorkerAssignment.agentId` | `hostId` |
| `WorkerAssignment.pluginId` | `workerId` |
| current `WorkerAssignment.workerId` | remove configured-instance meaning |
| `secretRefs` on configured Worker | replace with Credential Profile reference at assignment time |
| current Cloud `credentials` table | replaced by Credential Profiles/Grants; Host secrets stay in the OS secure store |
| `multi-agent-ensemble.ts` | rename/rewrite as multi-worker execution |
| Studio Agents page | Hosts |
| Studio Plugins page | Workers catalog |
| Studio configured Workers page | Accounts + Worker availability |
| Agent local Workers/Plugins UI | reduce to Host status/local actions |

## 3. Keep with minimal change

### Goal / Run / Task / Attempt

Keep the domain model and verification philosophy.

These are product-level concepts independent of v4 execution simplification.

### Artifacts / Findings / Verifications / Events

Keep.

They provide the evidence/audit layer that differentiates Conclave from a simple model router.

### Execution policies

Keep:
- single;
- parallel;
- synthesize;
- compare-and-select;
- competitive implementation;
- budgets/fallbacks.

Refactor only the execution-target identity.

### Cloudflare stack

Keep:
- Workers;
- Workflows;
- D1;
- R2;
- Durable Objects.

Rename Agent-specific bindings and messages to Host terminology.

### Worker process isolation

Keep.

The current Dart process/tree/permission work is valuable and becomes Host runtime internals.

### Secure credential primitives

Keep platform credential backends.

Refactor storage keys/namespaces around Credential Profiles rather than Agent Worker secret lists. V4-8 now keys local secrets by Host, Worker, and Credential Profile, with metadata-only Cloud status reporting. V4-9 adds use-only grants with expiry and usage limits plus requester-attributed usage records.

## 4. Refactor heavily

### `packages/core/src/entities.ts`

Current execution entities:
- `ConclaveAgent`;
- `WorkerPlugin`;
- `WorkerPluginVersion`;
- configured `Worker`;
- `WorkerAssignment` containing Agent + Plugin + Worker IDs.

Target:
- `Host`;
- `HostWorkspaceBinding`;
- `Worker` (catalog/integration);
- `WorkerVersion`;
- `HostWorkerInstallation`;
- `CredentialProfile`;
- `CredentialGrant`;
- `WorkerAssignment` with Host + Worker + Credential Profile.

### `apps/worker/src/assignment-dispatcher.ts`

The v4 scheduler resolves a Worker dynamically from task requirements, catalog availability, project preferences, user billing preference, online Hosts, active installations, capacity, budget, independence, and authorized Credential Profiles. The result is frozen into one immutable ResolvedExecutionTarget assignment snapshot. Configured Worker rows are no longer an execution identity.

Target scheduler resolves an ephemeral Execution Target:
- eligible Host;
- Worker availability/install readiness;
- eligible Credential Profile;
- model/config;
- capacity;
- independence;
- cost.

The resulting snapshot is persisted in Attempt/Assignment.

### `apps/worker/src/host-gateway.ts`

Keep Durable Object/WebSocket behavior.

Rename to Host Gateway and simplify desired-state payload:
- desired Worker versions;
- credential metadata/readiness requests;
- pending Assignments;
- Host policy/update info.

Do not sync configured Worker instances; sync Worker catalog availability and Host installations only.

### `apps/host/lib/worker_manager.dart`

The implementation is valuable.

WorkerManager owns the local Worker package lifecycle:
- catalog Worker package;
- installed versions;
- desired versions;
- signature verification;
- process spec;
- rollback;
- garbage collection.

Keep Worker terminology throughout the local package and runtime APIs.

### `apps/host/lib/worker_manager.dart` desired state

Cloud desired Worker IDs and version policies are reconciled directly by
WorkerManager. There is no persisted per-configured-instance Worker list.

### `apps/host/lib/main.dart`

Do not preserve the Agent App <-> Engine IPC architecture.

Reuse useful views/actions in one Host Flutter app:
- pairing;
- status;
- credentials requiring local action;
- permissions;
- logs;
- update.

Delete duplicated Workers/Plugins management screens that belong in Studio.

## 5. Delete after replacement

- separate Agent Engine executable/bootstrap;
- Agent App/Engine local IPC;
- Agent naming throughout active protocol;
- Plugin naming throughout active product/domain protocol;
- configured Worker-instance CRUD;
- roles/capabilities stored redundantly on configured Worker rows;
- secretRefs stored on configured Worker rows;
- v3 Agent enrollment/session/release table names;
- v3 Worker Plugin tables;
- v3 Agent Plugin Install table;
- old Cloud encrypted `credentials` model after Credential Profiles land;
- active v3 architecture docs once v4 is merged.

## 6. Database reset recommendation

Because the product is not in production:

1. Do not write a compatibility migration from the v3 fleet schema.
2. Keep the current schema in Git history only.
3. Build a new `0001_conclave_v4.sql`.
4. Reset development D1.
5. Seed only intentional development fixtures.
6. Delete compatibility aliases and old table repositories in the same migration window.

This is materially simpler than preserving:
- Agents;
- Worker Plugins;
- configured Workers;
- old Credentials;
- Connections.

## 7. Source quality observations

### Good patterns already present

- immutable assignment IDs/idempotency;
- typed protocols;
- explicit process supervision;
- signed package verification;
- platform abstraction work;
- focused Flutter stores beginning to emerge;
- Cloud route extraction;
- current clean migration baseline.

### Patterns to improve in v4

- remove version names from current source concepts;
- avoid giant composition files;
- prefer feature/domain folders over technology-only folders;
- remove duplicate role/capability storage;
- separate credential authorization from Worker configuration;
- derive runtime Worker availability from Host state rather than persisting too many mutable flags;
- use explicit state transition functions instead of scattered SQL updates;
- replace "multi-agent" naming with "multi-worker";

V4-12 completes the active orchestration rename. Candidate snapshots carry
Host, Worker, Credential Profile, provider/model, and session identity. The
default independence dimensions are session, credential, model, and provider;
Host diversity is operational only and must be explicitly requested, so two
Hosts running the same model and session are not treated as intellectually
independent.

V4-13 migrates the first-party Echo, Codex, Claude Code, Anthropic, OpenAI, and
Forge packages to v4 Worker manifests and the canonical Worker JSON-RPC
surface. Their manifests declare Host compatibility, credential-profile policy,
session/concurrency behavior, permissions, usage/billing metadata, digest, and
signature. Provider Workers receive assignment configuration and opaque
credential-profile references; raw credentials remain outside assignment data.

V4-14 brings subscription-backed Web AI through the same lifecycle: Host-owned
Web AI Worker, private Credential Profile, leased session, and immutable
assignment identity. The Cloud connector remains a mailbox/callback relay; it
does not execute provider work. Sessions are profile-bound, support reconnect,
waiting-for-user, quota, and fallback states, and cannot be reused across
profiles.

V4-15 reduces the Host desktop UI to machine operations: pairing, health,
local account actions, repository and permission status, Worker diagnostics,
logs, updates, and quitting. Projects, Chats, orchestration, Workspace
management, configured Worker CRUD, and Worker catalog management are not
present in the Host UI. Advanced Host identity and connection details are
progressively disclosed behind an accessible details panel.

V4-16 updates Studio execution UX to expose Hosts, Workers, and Accounts as
separate v4 concepts. Host cards show presence, bindings, load, installed
Workers, and updates; Worker cards show capabilities, ready Hosts, and
connected Accounts; Account cards show Credential Profile owner, Worker,
Host, sharing, usage, and auth state. The chat composer defaults to Auto and
Balanced, with explicit advanced controls for Worker, model, Account, Host,
candidate count, and cost. Navigation collapses into a drawer at medium and
narrow widths without hover-only actions.

V4-17 makes Studio explicitly web-only at `apps/studio`. Native Flutter
targets and desktop project metadata are not part of the package. Projects,
Chats, and Runs have browser URLs; push/replace state and pop-state keep
refresh, back, and forward navigation inside the same Cloud-backed app.
Unauthenticated sessions redirect to sign-in with a return URL. Responsive
breakpoints retain the wide sidebar and compact drawer/single-column layout,
while multiple browser tabs keep independent navigation state. The existing
Cloud HTTP/refresh path remains the only Studio realtime mechanism.
- make Studio read models purpose-built instead of one large snapshot response over time.

## 8. Suggested source organization

### Cloud

```text
apps/cloud/src/
  app/
    router.ts
    bindings.ts
  auth/
  workspaces/
  projects/
  chats/
  orchestration/
  hosts/
  workers/
  credentials/
  assignments/
  artifacts/
  usage/
```

Each feature owns:
- API handlers;
- service/application logic;
- persistence port calls;
- tests.

Domain rules remain in packages/core where cross-feature.

### Studio

```text
apps/studio/lib/
  app/
  design_system/
  features/
    auth/
    projects/
    chat/
    runs/
    hosts/
    workers/
    accounts/
    settings/
  shared/
```

Within a feature:
- view;
- view model/controller;
- repository;
- models.

### Host

```text
apps/host/lib/
  app/
  runtime/
    cloud/
    assignments/
    workers/
    credentials/
    repositories/
    processes/
    updates/
  features/
    status/
    accounts/
    permissions/
    logs/
    settings/
```

Avoid a separate Engine application unless future measured reliability requirements justify reintroducing it.

## 8.1 Authentication and workspace authorization

V4-18 uses the existing managed-session/OIDC-compatible identity boundary and
keeps User, Workspace, membership role, and explicit CredentialGrant records
authoritative in Cloud/D1. Canonical permissions are `host.view`,
`host.manage`, `worker.install`, `credential.create`, `credential.share`,
`credential.use`, `run.start`, and `run.control`.

Credential use is checked against the requester’s workspace, profile owner,
sharing policy, and active non-expired grant. Grants authorize use only; they
never authorize secret reads. Host machine tokens are accepted only for an
active `host_workspace_bindings` row, so a Host cannot cross Workspace
boundaries through the transient gateway.

V4-19 stores Host desired state in `host_desired_states` and
`host_desired_workers`. Studio updates are authorized and tenant-scoped;
required versions are rejected unless they are active, non-revoked Worker
catalog entries. Hosts receive only the resolved package metadata during sync,
then reconcile idempotently through the existing signed WorkerManager,
reporting observed status and errors back to Cloud.

V4-20 namespaces provider history by Worker, Credential Profile, optional
Project, session mode, and session ID. `fresh` sessions never reuse history;
task, chat, and project sessions can only continue within the same namespace.
Interactive assignments also carry the requesting Conclave user when known,
preventing two users on a shared Host/profile from claiming one another's
provider session.

V4-21 Forge execution resolves and persists Host + Worker + Credential Profile
targets for implementation, review, research, and runtime work. Forge consumes
assignment results and machine evidence; provider routing remains inside the
Worker boundary, and v4 Forge dispatch writes immutable `worker_assignments`
instead of configured Worker or Agent/Plugin records.

## 9. Architectural deletion gate

Architecture v4 cleanup is complete when active source search returns no product/domain usage of:
- `AgentEngine`;
- `ConclaveAgent`;
- `WorkerPlugin`;
- `pluginId` in assignment/domain routing;
- configured Worker-instance CRUD;
- Agent/Plugin navigation labels;
- `agent_plugin_installs`;
- `worker_plugins` (legacy name);
- v3 Architecture as normative.

Historical Git commits are not part of the gate.
