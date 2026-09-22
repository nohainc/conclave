# Architecture v2 Migration Map

> **Historical: superseded by [Migration to Architecture v3](MIGRATION_TO_V3.md). Do not use this document to plan new work.**

This document maps the current repository to Architecture v2.

## 1. Keep largely unchanged

These concepts remain valuable:

- Goal / Run / Phase / Task / Attempt domain model;
- completion criteria;
- verification gates;
- Findings;
- immutable Artifacts;
- Task graph;
- execution policies;
- multi-worker candidate Attempts;
- synthesis/evaluation decisions;
- quality presets;
- fallback policy;
- cost/budget controls;
- isolated implementation workspaces;
- D1/R2 persistence abstraction;
- Cloudflare Workflows;
- CI evidence;
- tenant authorization concepts;
- interactive connector session contracts;
- Flutter Studio codebase;
- Forge workflow as the first workflow.

## 2. Refactor

### `packages/core/src/worker-registry.ts`

Current:
`WorkerResource -> ConnectionResource`.

Target:
`WorkerInstance -> Agent + WorkerPluginVersion`.

Remove direct provider/local/web Connection as the Core scheduling unit.

Execution location becomes Agent identity/capability.

### `packages/core/src/worker-execution.ts`

Keep the provider-independent execution request/result idea.

Rename/reshape to assignment protocol:
- Cloud creates WorkerAssignment;
- Agent executes;
- result returns by assignment id.

Remove assumptions that Cloud owns a direct WorkerExecutor implementation.

### `apps/worker/src/runtime-connection.ts`

Rename/rebuild as Agent Gateway.

Current runtime scope is Project-oriented and connection-local.

Target:
- machine Agent identity;
- Workspace scope;
- one long-lived Agent session;
- many Workers;
- many Runs/Projects;
- durable assignment reconciliation;
- heartbeat/presence/version/plugin inventory.

### `packages/local-runtime`

Do not delete.

Move its safe repository/shell/git/process primitives behind the Conclave Agent runtime.

Codex/Claude code currently inside this package become first Worker Plugin implementations or reference plugins.

### `packages/providers`

Direct provider calls should not remain in the authoritative Cloud execution path.

Move provider-specific execution into Worker Plugin packages hosted by Conclave Agent.

This package may become:
- plugin SDK helpers;
- test fixtures;
- legacy adapter during migration.

### `apps/worker/src/forge-execution.ts`

Keep Cloud orchestration logic.

Replace direct provider/runtime adapter creation with:
- Worker selection;
- Agent assignment dispatch;
- wait for WorkerAssignment result.

Forge should not import provider-specific executors.

### `packages/core/src/interactive-connector.ts`

Keep mailbox/session concepts.

Re-scope connector session to a Worker owned by an Agent.

Cloud connector is relay transport, not direct Worker execution.

### Studio

Existing Run dashboard becomes advanced Run details.

Primary UI becomes Workspace/Project/Chat.

## 3. Replace/deprecate

### ConnectionResource

Deprecate as public Core concept.

Replacement:
- Agent;
- WorkerPluginVersion;
- Worker.

Temporary compatibility adapters may exist during migration.

### Local Runtime as top-level product

Replace product term with Conclave Agent.

Local Runtime remains an internal library used by Agent plugins.

### Direct Cloud provider execution

Deprecate.

Even API model calls execute through a Conclave Agent Worker Plugin.

### Cloud-owned Worker adapter secrets

For v1 prefer Agent-local credentials.

Retain encrypted Cloud credential work only as optional future shared-secret vault.

## 4. New major entities

Add:

- User;
- Workspace;
- WorkspaceMembership;
- AuthSession;
- Project;
- ProjectMembership optional;
- Chat;
- ChatMessage;
- ConclaveAgent;
- AgentEnrollment;
- AgentSession;
- AgentAssignment;
- AgentUpdateRelease;
- WorkerPlugin;
- WorkerPluginVersion;
- Worker;
- WorkerSecretRef;
- WorkerHealth;
- WorkerPluginInstall;
- PluginPermissionApproval.

## 5. Database strategy

The project is pre-production.

Do **not** accumulate many compatibility migrations for obsolete concepts.

Recommended approach:
1. preserve current migration directory in a tagged Git commit;
2. create a fresh Architecture v2 development D1 database;
3. squash the control-plane schema into a new clean migration baseline;
4. create a small seed/migration script only for any development data worth preserving;
5. keep old DB only temporarily for comparison;
6. remove old Connection tables from the new baseline.

This is the cheapest point in the project to simplify the schema.

## 6. Package target structure

Recommended:

```text
apps/
  cloud/
  studio/
  agent/

packages/
  core/
  protocol/
  persistence/
  security/
  orchestration/
  plugin-manifest/
  agent-protocol/
  testkit/

worker-plugins/
  openai/
  anthropic/
  codex/
  claude-code/
  git/
  shell/
  test-runner/
```

Flutter can remain under the current app path during migration; renaming directories is optional and should not block architecture work.

## 7. Compatibility strategy

Migrate vertically:

1. introduce new Agent/Plugin/Worker model beside old Connection model;
2. implement one end-to-end Worker through Agent;
3. switch Forge to Agent assignment;
4. convert Codex/Claude/provider adapters;
5. remove direct Connection execution;
6. delete obsolete tables/code after all tests use v2 path.

Do not rewrite every subsystem simultaneously.
