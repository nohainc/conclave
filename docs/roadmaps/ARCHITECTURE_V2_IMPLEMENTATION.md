# Architecture v2 Implementation Roadmap

This roadmap is designed for delegation to AI coding agents.

Each phase should be implemented in a separate branch/PR or a small sequence of tightly related PRs. The implementing AI must read:
- `AGENTS.md`;
- `ARCHITECTURE.md`;
- `docs/architecture/ARCHITECTURE_V2.md`;
- this roadmap;
- relevant existing specifications.

Do not begin a later phase while an earlier phase's exit criteria are red unless explicitly documented.

# Phase V2-0 — Stabilize main and freeze architecture

## Goal
Start the migration from a green, documented baseline.

## Work
- fix current Flutter `flutter analyze` failure;
- run Flutter tests after analyze passes;
- ensure TypeScript `pnpm check` remains green;
- verify Wrangler startup checks;
- mark Architecture v2 as normative;
- add a short ADR stating Cloud-first orchestration and Agent-only execution;
- mark contradictory old sections/specifications as superseded or transitional;
- stop adding new transport features to the legacy Connection model.

## Tests
- complete CI green;
- documentation link checker if available.

## Exit
- `main` CI fully green;
- one unambiguous architecture source of truth.

# Phase V2-1 — Define v2 domain contracts

## Goal
Introduce the new Cloud -> Agent -> Worker Plugin -> Worker model without changing execution yet.

## Work
Define typed Core entities:
- Workspace;
- ConclaveAgent;
- AgentStatus;
- AgentCapabilities;
- WorkerPlugin;
- WorkerPluginVersion;
- Worker;
- WorkerAvailability;
- WorkerAssignment;
- WorkerAssignmentResult;
- AgentEnrollment;
- AgentSession.

Define invariants:
- Worker belongs to one Workspace;
- Worker is hosted by one Agent;
- Worker references one plugin/version policy;
- every assignment targets one Worker;
- every assignment maps to one Task Attempt;
- Agent never decides follow-up orchestration.

Keep execution policies and Task/Attempt unchanged.

## Migration
Add compatibility mapping from current WorkerResource/ConnectionResource for tests only.

## Tests
- entity validation;
- cross-Workspace rejection;
- invalid Agent/Worker/plugin references;
- assignment idempotency types.

## Exit
Core can describe v2 execution without provider/transport concepts.

# Phase V2-2 — Define Agent protocol

## Goal
Create a versioned wire protocol between Cloud and Conclave Agent.

## Work
Add `packages/agent-protocol`.

Messages:
- hello;
- enrollment;
- heartbeat;
- capability inventory;
- plugin inventory;
- worker inventory;
- desired configuration;
- assignment start/ack/progress/result/error/cancel;
- artifact references;
- update commands;
- reconciliation after reconnect.

Requirements:
- protocol version;
- correlation IDs;
- idempotency keys;
- timestamps;
- sequence/order where needed;
- max payload sizes;
- structured error classes.

## Tests
- schema parsing;
- backwards/unsupported version rejection;
- malformed message rejection;
- duplicate assignment result;
- reconnect journal reconciliation.

## Exit
Protocol is transport-independent and fully contract-tested.

# Phase V2-3 — Clean Architecture v2 database baseline

## Goal
Stop carrying obsolete schema into a pre-production product.

## Work
Create a fresh development D1 database and clean schema baseline.

Tables include:
- users;
- auth_sessions;
- workspaces;
- workspace_memberships;
- projects;
- project_memberships if retained;
- chats;
- chat_messages;
- goals;
- runs;
- phases;
- tasks;
- task_dependencies;
- attempts;
- completion_criteria;
- agents;
- agent_enrollments;
- agent_sessions/presence metadata;
- worker_plugins;
- worker_plugin_versions;
- agent_plugin_installs;
- workers;
- worker_assignments;
- artifacts;
- findings;
- verifications;
- decisions/events;
- budgets/usage;
- audit_log;
- CI evidence.

Remove `connections` and `worker_connections` from the clean baseline.

Keep R2 for large artifacts/plugin packages.

## Data
No production compatibility burden. Document reset procedure.

## Tests
- apply migration to empty D1;
- foreign-key integrity;
- tenant isolation fixtures;
- run reconstruction;
- Agent/Worker/plugin joins.

## Exit
All v2 entities persist without old Connection tables.

# Phase V2-4 — Multi-user authentication foundation

## Goal
Make Cloud a real multi-user service.

## Work
Implement:
- User identity;
- login/session abstraction;
- Workspace creation;
- personal Workspace on first login;
- Workspace membership;
- owner/admin/member/viewer roles;
- logout/session revocation;
- active Workspace selection;
- tenant-scoped request context.

Use secure browser sessions for Web Studio.
Desktop auth must use a secure OAuth/OIDC flow such as authorization code + PKCE.

Do not embed static bearer tokens.

The exact identity provider can remain behind an adapter; choose the first supported provider during implementation.

## Tests
- unauthenticated rejection;
- session expiration/revocation;
- Workspace A cannot access Workspace B;
- role permissions;
- CSRF/session security for browser mutations where applicable.

## Exit
Studio API can identify one User and one authorized Workspace for every request.

# Phase V2-5 — Workspace, Project, Chat API

## Goal
Build the user-facing information model before redesigning Studio.

## Work
Cloud API:
- list/create/update Workspaces where permitted;
- list/create Projects;
- optional Project membership;
- create/list Chats;
- append/list Messages;
- rename/archive Chat;
- link Message -> Goal/Run;
- search-ready identifiers/timestamps.

Define message kinds:
- user;
- conclave;
- status;
- approval;
- artifact/result reference;
- system.

## Tests
- tenant scope;
- Project scope;
- Chat message ordering;
- concurrent append/idempotency;
- archive permissions.

## Exit
A user can persist Projects and AI-style Chats through API only.

# Phase V2-6 — Conclave Agent application skeleton

## Goal
Create the real installed execution host.

## Work
Add `apps/agent` in TypeScript.

Agent responsibilities:
- config/bootstrap;
- secure local identity store abstraction;
- enrollment command/UI-less flow;
- outbound Cloud connection;
- heartbeat;
- host metadata;
- local work directory;
- plugin directory;
- worker process manager;
- assignment journal;
- logging;
- graceful shutdown.

Reuse safe primitives from `packages/local-runtime`; do not duplicate them.

For development, running from Node is acceptable. Packaging/self-contained distribution comes later.

## Tests
- starts/stops cleanly;
- isolated temp home;
- reconnect;
- journal persists across restart;
- no credentials logged.

## Exit
An Agent process can enroll and remain connected to Cloud without hosting any Worker yet.

# Phase V2-7 — Agent enrollment and Agent Gateway

## Goal
Replace RuntimeConnection with real machine-level Agent connectivity.

## Cloud work
Create Agent Gateway using Durable Objects/WebSocket.

Implement:
- one-time enrollment;
- durable Agent record;
- credential rotation/revocation;
- online/offline presence;
- one live session per Agent policy;
- heartbeat timeout;
- desired config retrieval;
- reconciliation.

Refactor or replace `RuntimeConnection`.

## Agent work
- enrollment token exchange;
- durable machine credential;
- reconnect with backoff;
- heartbeat;
- protocol negotiation.

## Tests
- revoked Agent rejected;
- Workspace mismatch rejected;
- duplicate sessions policy;
- disconnect/reconnect;
- stale presence cleanup.

## Exit
Studio/Cloud accurately shows Agent online/offline/version.

# Phase V2-8 — Worker Plugin package specification and SDK

## Goal
Make integrations downloadable instead of hard-coded into Agent.

## Work
Create `packages/plugin-sdk`.

Define:
- manifest schema;
- lifecycle contract;
- Worker execution contract;
- configuration schema;
- secret requirements;
- permission manifest;
- health check;
- cancellation;
- progress;
- artifact output;
- supported Agent versions/platforms.

Define package layout and deterministic archive format.

## Security
- SHA-256 digest;
- signature verification interface;
- publisher identity;
- no unsigned stable packages.

## Tests
- valid package;
- tampered package;
- incompatible Agent;
- invalid permission declaration;
- plugin crash isolation contract.

## Exit
A minimal sample plugin can be packaged and validated.

# Phase V2-9 — Cloud Plugin Registry

## Goal
Store and distribute Worker Plugins centrally.

## Work
D1 registry metadata + R2 packages.

API:
- list compatible plugins;
- plugin/version metadata;
- publish flow for internal/dev use;
- download signed package;
- release channels;
- revoke version;
- compatibility query.

Initial publishing may be repository/CI-controlled rather than user marketplace publishing.

## Tests
- digest mismatch;
- revoked version;
- compatibility filtering;
- Workspace policy;
- package download authorization.

## Exit
Agent can discover a compatible signed plugin version from Cloud.

# Phase V2-10 — Agent self-update subsystem

## Goal
Make Conclave Agent maintainable without manual reinstall.

## Work
Define signed Agent release manifest.

Agent:
- checks current channel;
- downloads;
- verifies;
- stages;
- waits for safe point;
- restarts;
- health checks;
- rolls back on failed startup.

Cloud:
- current/minimum supported Agent versions;
- release channels;
- forced security update flag.

## Tests
- valid update;
- bad signature;
- interrupted download;
- active assignment delays restart;
- failed update rollback.

## Exit
Development Agent can update itself between two test versions safely.

# Phase V2-11 — Plugin manager and plugin updates

## Goal
Agent automatically installs only Workers it needs.

## Work
Agent:
- receives desired Worker config;
- resolves required plugin versions;
- downloads missing package;
- verifies digest/signature;
- installs version side-by-side;
- starts plugin process;
- health checks;
- drains/upgrades;
- rollback;
- removes unused versions by retention policy.

Cloud records installed/active versions.

## Tests
- install;
- no-op when already installed;
- upgrade;
- downgrade/rollback;
- incompatible version;
- plugin crash;
- multiple Workers sharing one plugin version.

## Exit
Creating a Worker in Cloud can cause Agent to automatically install its plugin.

# Phase V2-12 — Worker management

## Goal
Replace Worker/Connection configuration with Agent-hosted Workers.

## Work
Cloud Worker fields:
- Agent;
- Plugin/version policy;
- name;
- roles;
- capabilities;
- non-secret config;
- secret references/status;
- billing mode;
- independence key;
- concurrency;
- enabled/status.

Agent:
- materializes Worker configuration;
- validates plugin config;
- checks local secrets;
- advertises Worker health.

Studio/API:
- create/edit/enable/disable Worker;
- choose Agent;
- show configuration requirements;
- show missing secret/authentication state.

## Secrets
For v1, local execution secrets remain on Agent in OS secure storage where possible.

Cloud stores only secret reference/status.

## Tests
- same plugin multiple Workers;
- Agent offline;
- missing secret;
- Worker disabled;
- Workspace scope.

## Exit
Cloud resolves a Task to a configured online Worker hosted by an Agent.

# Phase V2-13 — First Worker Plugin: deterministic test worker

## Goal
Prove the complete Agent/plugin path without model-provider complexity.

## Work
Create a simple signed worker plugin that:
- accepts WorkerAssignment;
- returns structured deterministic result;
- supports progress/cancel;
- emits an Artifact.

End-to-end:
Cloud -> Agent -> plugin -> Worker -> result -> Cloud.

## Tests
- success;
- cancellation;
- timeout;
- duplicate result;
- Agent disconnect/reconnect mid-assignment.

## Exit
No legacy Connection executor is needed for one complete Task.

# Phase V2-14 — Migrate Codex and Claude Code to Worker Plugins

## Goal
Preserve current valuable local-agent work while moving it behind v2.

## Work
Extract current Codex/Claude logic from `packages/local-runtime` into Worker Plugins.

Reuse:
- safe process execution;
- repository scopes;
- cancellation;
- output bounds;
- structured result parsing.

Agent-local subscription/session remains local.

Cloud sees ordinary Workers only.

## Tests
- mocked CLIs;
- session unavailable;
- timeout;
- structured response correlation;
- repo permission denial;
- cancellation.

## Exit
Forge can execute a Task through Codex and Claude Code v2 Workers.

# Phase V2-15 — Migrate API providers into Worker Plugins

## Goal
Enforce the rule that Cloud never calls model providers directly.

## Work
Convert OpenAI/Anthropic current provider adapters into Agent-hosted Worker Plugins.

Decide credential location for v1:
- default Agent-local API key;
- optional Cloud secret vault deferred.

Remove provider-specific executors from Cloud production path.

## Tests
- mocked HTTP;
- rate limits;
- retryable/non-retryable error mapping;
- structured output validation;
- API cost/usage reporting.

## Exit
Search confirms Cloud orchestration does not import/call provider adapters.

# Phase V2-16 — Assignment dispatcher and Forge migration

## Goal
Make all real orchestration dispatch through Agents.

## Work
Create durable `worker_assignments`.

Flow:
1. Cloud creates Attempt.
2. Worker selected.
3. assignment persisted.
4. Agent Gateway delivers assignment.
5. Agent ACKs.
6. Worker executes.
7. progress optional.
8. terminal result persists.
9. Workflow receives completion event.
10. Core validates result and advances.

Refactor Forge execution to use AssignmentDispatcher only.

Remove direct WorkerExecutor creation from Forge Cloud code.

## Offline policy
Support:
- wait;
- reroute;
- fail;
according to execution policy.

## Tests
- idempotency;
- retry;
- reroute;
- Agent offline;
- late result after reroute;
- write-task duplicate prevention.

## Exit
One real Forge read-only Task runs exclusively through v2 assignment path.

# Phase V2-17 — Multi-worker execution on multiple Agents

## Goal
Reuse existing ensemble logic over distributed Workers.

## Work
Adapt:
- single;
- parallel;
- synthesize;
- compare/select;
- fallback;
- quality presets.

Scheduling considers:
- online Agent;
- Worker availability;
- role/capability;
- independence;
- concurrency;
- cost;
- Workspace/Project allowance.

No orchestration logic moves into Agent.

## Tests
- candidates on two Agents;
- one Agent drops;
- provider/model independence;
- budget ceiling;
- synthesis Worker on third Agent;
- deterministic accepted result.

## Exit
Architecture/design Task can run on 2+ Workers across machines and synthesize.

# Phase V2-18 — Web/cloud interactive Worker Plugin

## Goal
Preserve low-cost browser/subscription model participation within the Agent-only rule.

## Work
Convert current interactive connector into:
- Cloud relay endpoint;
- Agent-hosted web Worker plugin;
- WorkerSession owned by Worker/Agent;
- mailbox/pull tools;
- structured submit/result.

Cloud relay never calls the web model directly.

Support:
- external conversation reference if available;
- fresh chat/session policy;
- waiting_for_user;
- quota/unavailable;
- fallback to other Worker.

## Tests
- claim task;
- context pull;
- follow-up mailbox;
- structured result;
- Agent disconnect;
- web session lease expiry.

## Exit
A ChatGPT/Claude-style web Worker completes a Research candidate without provider API billing through Cloud.

# Phase V2-19 — Chat-first Studio redesign

## Goal
Make Studio look like an AI product rather than primarily a Run dashboard.

## Work
Navigation:
- Workspace switcher;
- + New Chat;
- Projects with nested Chats;
- Agents;
- Workers;
- Plugins;
- Settings/profile.

Chat:
- ordered Messages;
- compose/send;
- attachments/references later;
- inline Run card;
- streaming/progress status;
- clarification/approval;
- final result and Artifacts.

Run dashboard remains as `Open run details`.

Remove hard-coded personal identity from UI.

## Data layer
Replace monolithic StudioSnapshot with scoped stores/services:
- Session/WorkspaceStore;
- ProjectStore;
- ChatStore;
- RunStore;
- AgentStore;
- WorkerStore;
- PluginStore.

## Tests
- empty Workspace;
- new Project;
- new Chat;
- send message;
- Run progress;
- switch Project/Chat;
- multi-user author labels;
- narrow/mobile layout.

## Exit
The primary path from login to sending a Conclave request requires no dashboard knowledge.

# Phase V2-20 — Message -> Goal intent and conversation lifecycle

## Goal
Connect AI-style Chat semantics to orchestration safely.

## Work
When User sends message, classify/propose:
- conversational response;
- create new Goal;
- continue waiting Goal;
- create follow-up Goal referencing previous result.

Use an AI Lead/intent Worker for semantic recommendation when needed.

Core validates allowed transition.

Persist Message <-> Goal/Run correlation.

Do not send entire Chat transcript to Workers.

Build context from:
- current message;
- accepted Decisions;
- relevant Artifacts;
- Project instructions;
- explicit references.

## Tests
- first actionable request;
- follow-up implementation request;
- answer to approval;
- informational question;
- ambiguous intent;
- concurrent users in same Chat.

## Exit
One Chat can naturally contain multiple orchestrated Goals.

# Phase V2-21 — Workspace collaboration and invitations

## Goal
Complete basic multi-user functionality.

## Work
- invite user;
- invitation expiry;
- accept invite;
- member list;
- role change;
- remove/suspend;
- optional Project restriction;
- audit events;
- shared Chat access.

## Tests
- cross-tenant denial;
- owner protection;
- viewer mutation denial;
- revoked member loses access;
- two users see same Chat/Run.

## Exit
Two accounts can collaborate safely in one Workspace.

# Phase V2-22 — Agent/Worker/Plugin Studio management

## Goal
Let users configure the execution fleet graphically.

## Studio views
### Agents
- online/offline;
- host/OS;
- Agent version;
- update status;
- plugin inventory;
- load/current assignments;
- enroll/revoke/update.

### Plugin catalog
- description/version;
- permissions;
- compatibility;
- release channel;
- signed publisher;
- installed Agents.

### Workers
- create Worker;
- select Agent/plugin;
- configure roles/model/options;
- local credential setup status;
- health;
- enable/disable;
- cost/billing;
- quality-policy participation.

## Exit
A user can configure a new Worker without editing files/DB manually.

# Phase V2-23 — Agent installer and production packaging

## Goal
Make Agent practical to install.

## Work
Support at least macOS first:
- installer/package;
- background service/launch agent;
- secure storage;
- logs;
- update service;
- uninstall;
- enroll flow.

Then Windows/Linux.

Research the best TypeScript/Node packaging method at implementation time rather than locking it prematurely.

## Exit
Fresh macOS machine can install, enroll, self-update, and host one Worker.

# Phase V2-24 — Cloud deployment and development environment

## Goal
Run the complete v2 control plane on Conclave AX domain.

## Cloudflare
- `app.conclaveax.com` Studio + same-origin API;
- D1 v2 database;
- R2 artifacts/plugins;
- Workflows;
- Agent Gateway Durable Object;
- auth secrets/provider config;
- environment separation;
- migrations/seed.

Protect development environment until auth is ready.

## Exit
Web Studio and Agent connect to the deployed development Cloud.

# Phase V2-25 — End-to-end single-Agent Forge acceptance

## Goal
Prove Conclave AX v2 actually works.

Scenario:
1. User logs in.
2. Creates Project/Chat.
3. Enrolls Agent.
4. Adds Codex Worker.
5. Sends a bug-fix message.
6. Chat creates Goal/Run.
7. Lead/research Worker creates plan.
8. Codex implements on real fixture repo.
9. reviewer Worker reviews.
10. test Worker executes checks.
11. final verification completes.
12. result appears in same Chat.
13. restart Cloud/Agent and reconstruct state.

## Exit
No direct Cloud provider call and no legacy Connection execution path participates.

# Phase V2-26 — Multi-Agent / multi-model acceptance

## Goal
Prove distributed orchestration.

Use at least two Conclave Agents.

Scenario:
- research Worker A on Agent 1;
- research Worker B on Agent 2;
- synthesis;
- implementation on Agent 1;
- independent review on Agent 2;
- tests;
- completion.

Also test Agent failure/fallback.

## Exit
Cloud coordinates multiple Agents with correct audit/independence.

# Phase V2-27 — Interactive web Worker acceptance

## Goal
Prove subscription-backed web participation.

Scenario:
- two web Workers provide architecture candidates;
- Agent-hosted connector workers;
- Cloud relay;
- synthesis;
- no direct model API for candidates.

## Exit
Web Worker path uses same WorkerAssignment/Attempt lifecycle.

# Phase V2-28 — Security and supply-chain hardening

## Goal
Prepare for external users.

## Work
- plugin signing root/key rotation;
- Agent release signing;
- secure update transport;
- plugin permission enforcement;
- sandbox hardening;
- local secret redaction;
- dependency scanning;
- artifact retention;
- audit review;
- rate limits;
- invitation abuse protections;
- session hardening;
- Agent credential rotation;
- threat model;
- backup/export.

## Exit
Security checklist and threat model reviewed with no unresolved blockers.

# Phase V2-29 — Remove legacy architecture

## Goal
Delete migration scaffolding once v2 is proven.

Remove/deprecate:
- ConnectionResource production use;
- worker_connections tables;
- direct provider execution from Cloud;
- RuntimeConnection naming/API;
- Local Runtime product terminology;
- DemoStudioDataSource from product path;
- obsolete architecture docs.

Keep compatibility only where needed for tests/fixtures.

## Exit
Repository search confirms one execution architecture.

# Phase V2-30 — v0.1 release gate

Conclave AX v0.1 is ready when:

- CI green;
- authentication and tenant isolation proven;
- Studio chat-first flow works;
- one Agent installs/enrolls/self-updates;
- Agent downloads/updates signed Worker Plugins;
- API Worker plugin works;
- local Agent Worker plugin works;
- multi-worker policy works;
- at least two Agents can participate;
- Forge E2E works;
- web Worker flow works or is explicitly deferred from v0.1;
- no direct Cloud-to-model execution exists;
- audit/evidence reconstructs every Run;
- rollback and recovery are documented.

# Delegation rule

For each phase, use two AI steps:

1. **Planning/review worker** — inspect current code and turn the phase into small implementation tasks before coding.
2. **Implementation worker** — implement one small task/PR at a time.
3. **Independent review** — review the diff/tests before merging.

Do not ask one coding agent to implement multiple architecture phases in a single change.
