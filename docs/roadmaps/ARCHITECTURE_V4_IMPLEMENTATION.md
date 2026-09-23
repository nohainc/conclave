# Architecture v4 Implementation Roadmap — Host + Worker

**Status:** Proposed implementation plan  
**Architecture:** [ARCHITECTURE_V4.md](../architecture/ARCHITECTURE_V4.md)

This roadmap is intentionally detailed so each phase can be delegated directly to an AI planning/implementation/review workflow.

## Global implementation rules

Before every phase, the implementation worker must:
1. read `AGENTS.md`;
2. read `docs/architecture/ARCHITECTURE_V4.md`;
3. read `docs/architecture/V4_SOURCE_AUDIT.md`;
4. inspect current source rather than trusting this roadmap blindly;
5. keep changes within the current phase;
6. preserve a green main branch.

For every phase:
- use small PRs;
- add tests before deleting the replaced path;
- prefer schema-first contracts;
- preserve Cloud authority;
- never add provider-specific branching to orchestration Core;
- never persist long-lived raw secrets in ordinary task/assignment data;
- remove obsolete code in the same phase once replacement behavior is proven;
- do not maintain compatibility code for unused pre-production behavior.

---

## V4-0 — Freeze v4 and establish a green baseline

### Goal
Make v4 the only active architecture before implementation starts.

### Scope
- mark Architecture v4 normative;
- mark Architecture v3 historical;
- update `ARCHITECTURE.md`, `README.md`, `ROADMAP.md`;
- make ADR-004 the active execution decision;
- verify all current CI after ongoing cleanup;
- add architecture-boundary checks.

### Guard keywords
Warn/fail on new production usages of:
- `ConclaveAgent`;
- `AgentEngine`;
- `WorkerPlugin`;
- `agent_plugin_installs`;
- configured Worker-instance CRUD;
- new assignment routing based on `pluginId`.

Migration code being actively removed may be temporarily exempted.

### Deliverables
- top-level docs point to v4;
- implementation status checklist;
- fully green baseline;
- architecture guard script.

### Tests
- docs links;
- complete CI;
- boundary search.

### Exit criteria
A new AI coding worker sees only v4 as the implementation target.

---

## V4-1 — Define v4 canonical domain vocabulary

### Goal
Introduce the minimal execution model in Core.

### Add
- `Host`;
- `HostWorkspaceBinding`;
- `HostEnrollment`;
- `HostSession`;
- `HostRelease`;
- `Worker`;
- `WorkerVersion`;
- `HostWorkerInstallation`;
- `CredentialProfile`;
- `CredentialGrant`;
- `ResolvedExecutionTarget`;
- v4 `WorkerAssignment`;
- v4 `WorkerAssignmentResult`.

### Semantics
`Host` = one machine installation.  
`Worker` = installable AI/tool integration, e.g. Codex/OpenAI.  
`CredentialProfile` = whose account/auth is used.  
`ResolvedExecutionTarget` = ephemeral Host + Worker + Credential Profile + model/config/session snapshot.

Do not persist `ResolvedExecutionTarget` as a long-lived entity.

### Remove from new APIs
Do not add new dependencies on:
- `ConclaveAgent`;
- `WorkerPlugin`;
- configured Worker instance.

### Tests
- Host validation;
- multi-Workspace Host binding;
- private Credential Profile default;
- Workspace-owned Credential Profile;
- invalid grant;
- Assignment requires Host/Worker;
- assignment snapshot immutability.

### Exit criteria
Core can describe all v4 execution without Agent/Plugin/configured-Worker concepts.

---

## V4-2 — Redesign Worker manifest/package model

### Goal
Turn the current Plugin manifest into the v4 Worker package contract.

### Rename
`packages/plugin-manifest` -> `packages/worker-manifest`.

### Manifest
Include:
- `workerId`;
- version;
- display name;
- publisher;
- release channel;
- protocol version;
- minimum Host version;
- OS/architecture support;
- capabilities;
- permissions;
- credential requirements;
- credential sharing policy;
- configuration schema;
- session modes;
- concurrency model;
- entrypoint;
- digest/signature.

### Credential auth modes
- none;
- api_key;
- oauth_browser;
- local_cli_session;
- interactive/custom.

### Sharing policy
- `private_only`;
- `owner_controlled`;
- `workspace_capable`.

### Concurrency
Declare Worker package concurrency and whether persistent runtime is needed.

### Tests
- Codex/OpenAI/Anthropic manifests;
- no-auth Worker;
- bad sharing policy;
- incompatible Host;
- bad semantic version;
- undeclared credential requirement.

### Exit criteria
Every first-party Worker can be represented without Plugin terminology.

---

## V4-3 — Define schema-first Host and Worker protocols

### Goal
Replace Agent/Plugin protocols with Host/Worker protocols.

### Cloud <-> Host
Messages:
- host.hello;
- host.heartbeat;
- host.sync.request/result;
- host.status;
- host.update;
- worker.install/remove/status;
- credential.status;
- assignment.start/ack/progress/result/error/cancel.

### Host <-> Worker
Methods/events:
- initialize;
- health;
- describe;
- execute;
- progress;
- usage;
- artifact;
- result;
- cancel;
- shutdown.

### Assignment snapshot
Include:
- assignment/workspace/project/run/task/attempt IDs;
- requestedByUserId;
- hostId;
- workerId;
- resolved Worker version;
- credentialProfileId;
- model/config;
- session policy;
- permissions;
- context refs;
- timeout;
- idempotency key.

### Secret rule
Prefer opaque local Credential Profile references. Never transmit long-lived raw secrets unless a future Cloud vault explicitly requires scoped delivery.

### Code generation
Generate TypeScript and Dart from one canonical schema source.

### Tests
- TS/Dart roundtrip;
- protocol-version rejection;
- optional-field compatibility;
- malformed Worker event;
- duplicate assignment idempotency.

### Exit criteria
No new protocol message uses Agent/Plugin vocabulary.

---

## V4-4 — Create clean v4 D1 schema and reset development data

### Goal
Use the pre-production window to remove schema baggage.

### Strategy
Create `0001_conclave_v4.sql`; reset development D1. No compatibility migration.

### Keep/recreate
- users/auth;
- Workspaces/memberships/invitations;
- Projects;
- Chats/messages;
- Goals/Runs/Phases/Tasks/Attempts;
- completion criteria;
- verifications;
- artifacts/findings/events;
- budgets/usage/audit/CI evidence.

### Replace fleet tables
Remove:
- agents;
- agent_enrollments/sessions/releases;
- worker_plugins/versions;
- agent_plugin_installs;
- configured workers.

Add:
- hosts;
- host_workspace_bindings;
- host_enrollments;
- host_sessions;
- host_releases;
- workers;
- worker_versions;
- host_worker_installations;
- credential_profiles;
- credential_grants;
- worker_assignments.

### Credential Profile fields
At minimum:
- id/workspace;
- owner_type/owner_id;
- worker_id;
- host_id when local;
- display_name;
- auth_type;
- secret_location/reference;
- status;
- sharing_policy;
- provider_metadata;
- concurrency_limit.

### Cleanup
Review/remove obsolete:
- extensions;
- old credentials;
- model-call connection IDs;
- provider/connection-era compatibility fields.

### Tests
- empty D1 migration;
- FKs;
- tenant isolation;
- Host multi-Workspace binding;
- grants;
- assignment reconstruction;
- clean seed.

### Exit criteria
Fresh v4 D1 supports the target model with no v3 fleet tables.

---

## V4-5 — Rename Cloud execution plane Agent -> Host

### Goal
Migrate connectivity semantics without changing orchestration behavior.

### Refactor
- `agent-gateway.ts` -> `host-gateway.ts`;
- enrollment routes;
- Durable Object bindings;
- Cloudflare config;
- audit actor naming;
- tests.

### Host identity
Host owns machine credential, platform, version, capabilities and presence.

### Multi-Workspace
Implement Host <-> Workspace many-to-many binding. Initial UX may still bind only one Workspace.

### Presence
Durable Object is transient connectivity only; D1 remains authoritative.

### Tests
- Host enrollment;
- credential revoke;
- one Host/two Workspaces;
- invalid Workspace assignment;
- reconnect;
- stale presence;
- duplicate live session.

### Exit criteria
No active Agent Gateway path remains.

---

## V4-6 — Merge Agent App + Agent Engine into Conclave Host

### Goal
Replace the two-process product topology with one Flutter/Dart Host.

### New app
Create/rename `apps/host`.

Reuse runtime code from `apps/agent_engine` and useful UI from `apps/agent_app`.

### Remove after parity
- `apps/agent_app`;
- `apps/agent_engine`;
- local IPC;
- Engine bootstrap metadata;
- restart-via-IPC behavior.

### Host owns
- Cloud connection;
- assignment journal;
- Worker manager;
- secure credentials;
- process supervision;
- repository permissions;
- updater;
- logs;
- minimal UI.

### Window lifecycle
- close may hide/minimize;
- explicit Quit stops Host;
- assignments interrupted by quit must reconcile safely.

### Tests
- launch;
- minimize/restore;
- controlled quit;
- crash/restart journal recovery;
- child process cancellation.

### Exit criteria
One Host app replaces Agent App + Engine on macOS development.

---

## V4-7 — Convert PluginManager into WorkerManager

### Goal
Operate directly on Worker packages.

### Rename/refactor
- PluginManager -> WorkerManager;
- InstalledPlugin -> InstalledWorker;
- PluginManifest -> WorkerManifest;
- package directories to Worker naming.

### Desired state
Cloud sends Worker IDs/version policies and Host update policy.

Host:
1. resolves;
2. downloads;
3. verifies;
4. installs side-by-side;
5. health checks;
6. activates;
7. reports;
8. rolls back;
9. garbage-collects.

### Remove
- desired configured Worker list;
- per-configured-instance install logic.

### Tests
- install/update/rollback;
- revoked version;
- two users same Worker -> one installation;
- interrupted download;
- invalid signature.

### Exit criteria
Host manages Worker software directly; PluginManager no longer exists.

---

## V4-8 — Implement Credential Profiles and local secure storage

### Goal
Separate AI account identity from Worker installation.

### Ownership
- user-owned;
- Workspace-owned.

### Secret locations initially
- local Host secure store;
- none.

Defer Cloud secret vault.

### Local namespace
Key local secrets by Host + Worker + Credential Profile.

### Auth states
- setup_required;
- authenticating;
- ready;
- expired;
- error;
- revoked.

### Host local actions
- enter API key;
- browser OAuth;
- CLI login;
- clear/re-auth;
- filesystem permission.

### Cloud sees metadata only
No raw secret return.

### Tests
- A/B separate Codex accounts on one Host;
- private isolation;
- shared profile;
- revoke;
- wrong Host;
- secret redaction.

### Exit criteria
Two users share one Host/Worker while using independent credentials.

---

## V4-9 — Credential sharing and usage attribution

### Goal
Allow explicit safe sharing.

### Sharing
- private;
- selected users;
- workspace.

### CredentialGrant
Include:
- credentialProfileId;
- grantee;
- use permission;
- optional expiry;
- optional usage limit;
- createdBy/revokedAt.

Never grant secret-read.

### Authorization
Scheduler resolves profile only if requester owns it or has a valid grant.

### Usage
Record requester, credential owner, Worker, Host, model, tokens/cost/duration.

### Studio
Accounts page shows owner, sharing and consumption.

### Tests
- grant/revoke/expire;
- owner vs consumer;
- Workspace roles;
- provider private-only rule.

### Exit criteria
Shared paid accounts retain permission and cost attribution.

---

## V4-10 — Remove configured Worker instances

### Goal
Delete persistent "Codex Main / GPT Reviewer" instances.

### Replace with
Project defaults:
- preferred Workers/models/accounts;
- quality;
- budgets.

User preferences:
- preferred private account;
- subscription vs API preference.

Optional saved presets may be added later but are not execution identities.

### Scheduler
Resolve Worker dynamically from Task requirements and available accounts/Hosts.

### Studio
Delete "New Worker" CRUD. Replace with Workers catalog + Accounts + execution preferences.

### Tests
- same Codex Worker serves research/implementation;
- reviewer resolves by capability;
- Auto;
- explicit override;
- missing credential -> setup state.

### Exit criteria
Configured Worker-instance table/API/UI is gone.

---

## V4-11 — Rewrite assignment dispatcher around ResolvedExecutionTarget

### Goal
Resolve Host + Worker + Credential Profile directly.

### Algorithm
1. Task requirements;
2. bound online Hosts;
3. compatible Worker installations;
4. authorized Credential Profiles;
5. model/config requirements;
6. capacity;
7. budget/cost;
8. independence;
9. explicit user choice;
10. immutable Assignment snapshot.

### No provider branching
Provider/CLI specifics remain Worker-side.

### Capacity
Cloud queues globally; Host is final local authority and may return busy.

### Tests
- private/shared/Workspace account;
- Host offline;
- Worker installing;
- credentials missing;
- full concurrency;
- fallback;
- explicit selection.

### Exit criteria
Every Task assignment uses one v4 resolver.

---

## V4-12 — Multi-agent -> multi-worker orchestration

### Goal
Remove Agent-based ensemble identity.

### Rename
`multi-agent-ensemble.ts` -> `multi-worker-ensemble.ts`.

### Independence levels
- session;
- credential;
- model;
- provider;
- Host.

Do not equate different Hosts with intellectual independence.

### Persist candidate snapshot
Host + Worker + Credential Profile + provider/model + session.

### Tests
- same model fresh session;
- same provider/different model;
- different provider;
- different Host/same model;
- provider-independent review;
- synthesis;
- budgets.

### Exit criteria
No multi-agent terminology in active orchestration/UI.

---

## V4-13 — Migrate first-party Worker packages

### Goal
Rename/adapt `worker_plugins` -> `workers`.

### Migrate
- echo;
- codex;
- claude_code;
- openai;
- anthropic;
- forge if retained.

### Required
- v4 Worker manifest;
- Host protocol;
- Credential Profile ref;
- per-assignment config;
- session namespace;
- concurrency;
- usage;
- no Plugin terminology.

### Tests
Each Worker: health/auth/success/cancel/concurrency/profile isolation/usage/signature.

### Exit criteria
No first-party Worker uses v3 Plugin protocol.

---

## V4-14 — Web AI Worker migration

### Goal
Fit subscription-backed web AI into Worker + Credential Profile.

### Flow
Assignment -> Host -> Web AI Worker -> Credential Profile/session -> Cloud relay -> web AI.

### Rules
- web account Profile private by default;
- no cross-user session reuse;
- Cloud relay remains mailbox/callback, not executor.

### Tests
- A/B separate sessions;
- reconnect;
- waiting_for_user;
- quota;
- fallback.

### Exit criteria
Web AI uses the same Assignment lifecycle as every Worker.

---

## V4-15 — Simplify Host UI

### Goal
Make local UI machine-focused.

### Keep
- pairing;
- status;
- accounts needing local action;
- repositories/permissions;
- Worker diagnostics;
- logs;
- updates;
- Quit.

### Remove
- Projects/Chats;
- orchestration;
- Workspace management;
- configured Worker CRUD;
- Worker catalog management.

### UX
Progressive disclosure; normal users see setup/health, advanced diagnostics behind details.

### Tests
- first launch;
- paired;
- auth needed;
- active work;
- offline;
- install failure;
- accessibility.

### Exit criteria
Host UI is understandable without internal architecture knowledge.

---

## V4-16 — Redesign Studio execution UX

### Goal
Expose Hosts, Workers and Accounts clearly.

### Navigation
- Agents -> Hosts;
- Plugins -> Workers;
- configured Workers -> Accounts/execution settings.

### Hosts
Machine, online state, bindings, load, installed Workers, updates.

### Workers
Catalog cards with capabilities, ready Hosts, connected Accounts and install state.

### Accounts
Credential Profiles with owner, Worker, Host, sharing, usage and auth state.

### Chat composer
Default: Auto + Balanced.  
Advanced: Worker/model/Account/Host/candidates/cost.

### Accessibility/responsiveness
Wide sidebar, medium collapsible navigation, narrow single-column; no hover-only actions.

### Exit criteria
New user can pair Host, connect account, and execute without Agent/Plugin terminology.

---

## V4-17 — Web-only Studio cleanup

### Goal
Make Studio explicitly web-first.

### Scope
- use `apps/studio` as the web-only Studio package;
- remove desktop Studio targets/assumptions;
- deep-link Projects/Chats/Runs;
- browser refresh/back/forward;
- responsive Flutter Web.

### Realtime
Use one existing Cloud mechanism; do not add another backend.

### Mobile future
Keep reusable design/API/domain packages, but do not build mobile now.

### Tests
- refresh;
- deep links;
- auth redirect;
- breakpoints;
- reconnect;
- multiple tabs.

### Exit criteria
Studio is a polished web app with no desktop requirement.

---

## V4-18 — Authentication and Workspace authorization alignment

### Goal
Align human auth with Host/account sharing.

### Human auth
Managed/OIDC identity; Conclave owns User/Workspace/roles.

### Host pairing
Authorized User initiates pairing; Host then uses machine credential only.

### Permissions
Define:
- host.view/manage;
- worker.install;
- credential.create/share/use;
- run.start/control.

Use role + explicit grants, not a custom policy DSL.

### Tests
- member use vs admin manage;
- private account denial;
- shared account success;
- Host cross-Workspace denial.

### Exit criteria
Sharing is enforced by Cloud, not UI convention.

---

## V4-19 — Host desired-state controller

### Goal
Make setup automatic from Studio.

### Desired state
Per Host:
- required Worker versions;
- Host release channel;
- Workspace bindings;
- credential setup requests;
- local permission requests.

### Reconciliation
Receive -> compare -> install/update/remove -> report, idempotently.

### UX
Choosing Codex automatically installs it. Missing account prompts Connect account.

### Tests
- install once;
- two users same Worker;
- revoked version;
- retention cleanup;
- offline/reconnect;
- partial install.

### Exit criteria
Normal users never manually install Worker packages.

---

## V4-20 — Session/history isolation

### Goal
Prevent provider state leakage on shared Hosts.

### Namespace
Worker + Credential Profile + optional Project + session ID.

### Session modes
- fresh;
- task;
- chat;
- project.

Default fresh for independent research/review.

### Tests
- A/B same Worker simultaneous;
- shared Conclave output;
- isolated provider history;
- allowed reuse only within profile/policy.

### Exit criteria
Cross-user provider-session leakage tests pass.

---

## V4-21 — Forge migration

### Goal
Make Forge use only v4 concepts.

### Remove
Agent/Plugin/configured Worker/Connection-era routing.

### Flow
Tasks request capabilities; scheduler resolves v4 target; Forge consumes Assignment results/evidence only.

### Tests
Codex implementation, Claude review, API research, shared Host, different accounts, disconnect, correction loop, evidence.

### Exit criteria
Forge E2E uses Host + Worker + Credential Profile exclusively.

---

## V4-22 — Usage, budgets, shared-account accounting

### Goal
Make cost control useful for shared accounts.

### Record
Requester, Project, Worker, model/provider, Credential Profile, owner, Host, tokens/cost/duration.

### Budgets
Workspace/Project/Run and optional Credential Profile.

### Studio
Usage by Project/User/Account/Worker/provider.

Do not invent monetary cost for subscriptions if unknown.

### Tests
- shared account attribution;
- budget rejection;
- subscription category;
- API cost.

### Exit criteria
Account owner can see who used a shared paid account and how much.

---

## V4-23 — Security and supply-chain hardening

### Goal
Revalidate security after simplification.

### Threats
Malicious Worker, compromised Host, stolen Host credential, shared-account abuse, prompt injection/tool misuse, package tampering, path traversal, replay, cross-Workspace assignment.

### Supply chain
Signatures, trusted publisher, revocation, digest, rollback.

### Secrets
Platform secure store, process-scoped injection, redaction, temporary-memory cleanup.

### Permissions
Host independently enforces effective Assignment permissions.

### Exit criteria
No unresolved high-severity findings.

---

## V4-24 — Aggressive v3 cleanup

### Goal
Delete superseded implementation after v4 paths work.

### Delete/rename
- v3 Agent App/Engine;
- IPC;
- Agent protocol;
- Plugin protocol naming;
- Plugin manifest naming;
- configured Worker APIs/UI;
- old fleet repositories/tests/docs.

### Search gate
No product/domain usage of:
- `ConclaveAgent`;
- `AgentEngine`;
- `WorkerPlugin`;
- `agentId`;
- `pluginId`;
- `worker_plugins`;
- `agent_plugin_installs`;
- configured Worker CRUD.

Provider names containing "agent" are exempt.

### Exit criteria
Repository has one execution architecture.

---

## V4-25 — Clean-room rebuild and recovery

### Goal
Verify from empty state.

### From scratch
Fresh checkout -> dependencies -> protocol generation -> empty D1 -> v4 baseline -> Cloud -> Studio web -> Host -> pair -> auto-install Echo -> account -> assignment -> Codex/OpenAI -> multi-worker -> Forge.

### Recovery
Host crash/quit, Cloud restart, reconnect, Worker crash, update rollback, credential revoke, browser refresh.

### Exit criteria
All acceptance flows work from empty environment.

---

## V4-26 — High-quality UI/UX acceptance pass

### Goal
Polish after architecture stabilizes.

### Studio review
First-run comprehension, time-to-first-request, Host/account friction, empty/loading/error states, keyboard/accessibility, responsive behavior.

### Host review
Pairing, local auth prompts, filesystem permissions, background behavior, quit warning, logs/support.

### Design system
Standardize spacing, typography, surfaces, status, forms, banners, cards, navigation and progress.

### Error UX
Every error explains:
1. what happened;
2. whether work is safe;
3. what user can do;
4. whether retry is automatic.

### Exit criteria
No blocking first-run or execution-management usability issues.

---

## V4-27 — Architecture v4 release gate

### Required architecture
- web Studio;
- TypeScript/Cloudflare Cloud;
- one Host app/machine;
- installable Workers;
- Credential Profiles;
- no v3 execution architecture.

### Required Workers
- Echo/Test;
- Codex or equivalent;
- one API Worker.

Recommended:
- Claude Code;
- Web AI.

### Required flows
- multi-user Workspace;
- Host pairing;
- automatic Worker install;
- private account;
- shared account;
- Task execution;
- parallel candidates;
- synthesis/review;
- Forge;
- usage attribution;
- reconnect/recovery.

### Required quality
- all CI green;
- macOS Host acceptance;
- Windows/Linux compile/tests;
- tenant isolation;
- credential isolation;
- signed packages;
- protocol compatibility;
- accessibility smoke tests;
- docs match source.

### Exit criteria
A new user can sign in to Studio, pair one Host, choose a Worker, auto-install it, connect their own account, optionally share it, run a Chat request, receive a verified result, and inspect usage/evidence.

---

# Delegation template

Use this for each phase:

```text
Implement only Architecture v4 phase V4-N from
docs/roadmaps/ARCHITECTURE_V4_IMPLEMENTATION.md.

Before coding:
- inspect latest main;
- read ARCHITECTURE_V4.md and V4_SOURCE_AUDIT.md;
- identify reusable code;
- identify obsolete code to delete in this phase;
- prepare a small PR-sized implementation plan.

Requirements:
- do not add compatibility for unused pre-production behavior;
- preserve Cloud authority;
- keep provider behavior inside Worker implementations;
- add/update tests for each exit criterion;
- remove replaced source after replacement tests pass;
- keep CI green.

At completion report:
- files changed/deleted;
- tests and exact results;
- architecture invariants verified;
- remaining follow-up work.
```

For complex phases use:
1. planning/research Worker;
2. implementation Worker;
3. independent review Worker.
