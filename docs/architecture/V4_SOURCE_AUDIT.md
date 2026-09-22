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
| `apps/flutter_app` | Keep; rename to `apps/studio`; web-only target |
| `apps/worker` | Keep; rename to `apps/cloud` |
| `apps/agent_app` | Merge into `apps/host` |
| `apps/agent_engine` | Merge runtime code into `apps/host`; remove IPC/process split |
| `worker_plugins/*` | Keep implementations; rename directory to `workers/*` |
| `packages/agent-protocol` | Replace/merge into Host protocol |
| `packages/plugin-manifest` | Rename to `packages/worker-manifest` |
| `packages/dart/plugin_protocol` | Rename to Worker protocol |
| Agent Gateway | Rename/refactor to Host Gateway |
| Agent entities/tables | Replace with Host entities/tables |
| WorkerPlugin entities/tables | Replace with Worker catalog/version |
| configured `Worker` entity/table | Delete |
| `agent_plugin_installs` | Replace with `host_worker_installations` |
| `WorkerAssignment.agentId` | `hostId` |
| `WorkerAssignment.pluginId` | `workerId` |
| current `WorkerAssignment.workerId` | remove configured-instance meaning |
| `secretRefs` on configured Worker | replace with Credential Profile reference at assignment time |
| current Cloud `credentials` table | replace with Credential Profiles/Grants; no legacy AES-GCM assumption |
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

Refactor storage keys/namespaces around Credential Profiles rather than Agent Worker secret lists.

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

Current scheduler selects a configured Worker row joined to an Agent.

Target scheduler resolves an ephemeral Execution Target:
- eligible Host;
- Worker availability/install readiness;
- eligible Credential Profile;
- model/config;
- capacity;
- independence;
- cost.

The resulting snapshot is persisted in Attempt/Assignment.

### `apps/worker/src/agent-gateway.ts`

Keep Durable Object/WebSocket behavior.

Rename to Host Gateway and simplify desired-state payload:
- desired Worker versions;
- credential metadata/readiness requests;
- pending Assignments;
- Host policy/update info.

Do not sync configured Worker instances.

### `apps/agent_engine/lib/plugin_manager.dart`

The implementation is valuable.

Rename/reframe as WorkerManager:
- catalog Worker package;
- installed versions;
- desired versions;
- signature verification;
- process spec;
- rollback;
- garbage collection.

Remove Plugin vocabulary from user-facing protocol.

### `apps/agent_engine/lib/worker_configuration.dart`

Delete the current desired configured Worker list.

Replace with:
- desired Worker installations;
- Host policy;
- Credential Profile metadata.

### `apps/agent_app/lib/main.dart`

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

## 9. Architectural deletion gate

Architecture v4 cleanup is complete when active source search returns no product/domain usage of:
- `AgentEngine`;
- `ConclaveAgent`;
- `WorkerPlugin`;
- `pluginId` in assignment/domain routing;
- configured Worker-instance CRUD;
- Agent/Plugin navigation labels;
- `agent_plugin_installs`;
- `worker_plugins`;
- v3 Architecture as normative.

Historical Git commits are not part of the gate.
