# Architecture v5 Implementation Roadmap — Project-Centric Workspaces

**Status:** Proposed
**Architecture:** [ARCHITECTURE_V5.md](../architecture/ARCHITECTURE_V5.md)
**Date:** 2026-09-24

This roadmap intentionally separates architecture migration from feature expansion. Conclave is pre-production, so phases should remove replaced v4 behavior rather than preserve indefinite compatibility.

## Global implementation rules

For every phase:
1. read `AGENTS.md`;
2. read `docs/architecture/ARCHITECTURE_V5.md`;
3. inspect current source before changing it;
4. preserve a green main branch;
5. keep one architectural concern per PR;
6. add or update tests before deleting replaced behavior;
7. remove obsolete v4 paths in the same phase once replacement behavior is proven;
8. do not create dual long-term Host/Workspace concepts;
9. never make Project membership imply AI Account access;
10. never make Project membership imply unrestricted machine access.

## V5-0 — Freeze the v5 architecture decision

### Goal
Make the Project-centric Workspace model explicit before runtime changes begin.

### Work
- accept ADR-008;
- mark Architecture v5 normative;
- mark Architecture v4 historical;
- update top-level `README.md`, `ARCHITECTURE.md`, application docs, diagrams and vocabulary;
- add architecture guard terms for removed collaborative Workspace semantics.

### Guard against new usage
- Workspace membership as execution authorization;
- `host_workspace_bindings`;
- new `host.use` checks;
- new user-facing Host labels;
- new Workspace switching UI;
- new Workspace-owned Projects;
- new Workspace-owned credential logic.

### Exit criteria
Every new contributor understands: Project is collaboration; Workspace is execution.

---

## V5-1 — Define canonical v5 domain entities

### Goal
Introduce v5 domain vocabulary before touching transport/storage broadly.

### Add/define
- `ExecutionWorkspace` (user-facing: Workspace);
- `WorkspaceRuntimeIdentity`;
- `WorkspaceSession`;
- `WorkspaceEnrollment`;
- `WorkspaceWorkerInstallation`;
- `WorkspaceProjectGrant`;
- `ProjectMembership`;
- `ProjectInvitation`;
- `ProjectAccountGrant`;
- v5 `ResolvedExecutionTarget`;
- v5 `WorkerAssignment`.

### Remove from canonical model
- collaborative Workspace;
- WorkspaceMembership;
- WorkspaceRole;
- HostWorkspaceBinding.

### Tests
- Workspace has exactly one owner;
- Project has exactly one owner;
- Project member does not imply Workspace access;
- Workspace Grant is required for cross-user Project execution;
- AI Account grant is independent;
- effective permissions use intersection semantics.

### Exit criteria
Core can describe v5 without a collaborative Workspace.

---

## V5-2 — Design the Workspace Grant permission contract

### Goal
Define the most security-critical new v5 boundary before scheduler migration.

### Grant fields
- Project ID;
- Workspace ID;
- owner/grantor;
- status;
- scope type;
- repository/path mappings;
- allowed Worker IDs/capabilities;
- allowed Worker permissions;
- network policy;
- concurrency;
- expiry;
- optional budget.

### Initial scope presets
- `project_repository` — recommended default;
- `selected_paths`;
- `full_workspace` — advanced/high-trust.

### Permission intersection
Implement one deterministic function:

```text
effective =
  projectMember
  ∩ projectWorkspaceGrant
  ∩ workerManifest
  ∩ workspaceLocalPolicy
  ∩ projectPolicy
```

### Tests
- path escape;
- symlink escape;
- undeclared Worker permission;
- revoked grant;
- expired grant;
- collaborator vs viewer;
- full Workspace requires step-up;
- grant narrowing after assignment does not mutate historical snapshot.

### Exit criteria
Scheduler and runtime can consume one immutable effective permission object.

---

## V5-3 — Create a clean v5 D1 schema

### Goal
Use the pre-production window to remove v4 tenancy complexity.

### Replace
- `workspaces` collaborative tenant table;
- `workspace_memberships`;
- `workspace_invitations`;
- `host_workspace_bindings`;
- Workspace-owned Project foreign keys.

### Create
- Project ownership/membership/invitations;
- execution Workspaces owned by Users;
- Workspace runtime sessions/enrollments/releases;
- Workspace Worker installations/desired state;
- Workspace Project Grants;
- Project Account Grants.

### Refactor project-scoped tables
Chats, Goals, Runs, artifacts, findings, events and usage should derive authorization from Project, not collaborative Workspace membership.

### Strategy
Because production data does not need preservation:
- create a clean v5 baseline migration;
- keep v4 schema in Git history;
- reset development D1;
- avoid compatibility triggers/views.

### Tests
- clean SQLite apply;
- FK integrity;
- owner deletion rules;
- Project membership isolation;
- Workspace Grant isolation;
- AI Account isolation.

### Exit criteria
No active persistence rule requires collaborative Workspace membership.

---

## V5-4 — Refactor human authorization to User + Project

### Goal
Remove Workspace selection from browser authorization.

### Security context
Replace v4:
```text
User -> Workspace -> Project
```

with:
```text
User -> owned resources
User -> Project memberships
```

### Project permissions
Initial roles:
- owner;
- collaborator;
- viewer.

### User-owned resource permissions
A user can manage:
- their Workspaces;
- their private AI Accounts;
- their personal preferences.

### Remove
- `x-conclave-workspace-id`;
- active Workspace browser state;
- Workspace role permission inheritance;
- Workspace selection during security context resolution.

### Tests
- Project ID substitution;
- member removed during active session;
- viewer execution denial;
- collaborator Workspace management denial;
- owner-only Project deletion;
- direct URL access.

### Exit criteria
Every human request is authorized from User ownership or Project membership.

---

## V5-5 — Rename Host product/domain surfaces to Workspace

### Goal
Rename the user-facing and domain execution environment without weakening runtime identity.

### Rename product/UI
- Hosts -> Workspaces;
- Add Host -> Add Workspace;
- Host details -> Workspace details;
- Host online -> Workspace online.

### Rename domain/API
Prefer:
- `execution_workspace_id`;
- `workspace_runtime_*`;
- `WorkspaceGateway`.

### Preserve internally where useful during one migration PR
Low-level temporary aliases may exist while generated protocols migrate, but no user-visible Host copy should remain after this phase.

### Desktop application
Rename:
- Conclave Host -> Conclave Workspace;
- pairing copy;
- diagnostics;
- app bundle/package identifiers when safe;
- local data directory deliberately (migration not required for pre-production if reset is acceptable).

### Tests
- terminology search;
- Flutter text tests;
- package/build identifiers;
- desktop startup.

### Exit criteria
Users see Workspace, never Host, for execution environments.

---

## V5-6 — Refactor runtime protocol and Gateway

### Goal
Move Cloud <-> machine communication from Host/Workspace-binding semantics to Workspace runtime identity.

### Protocol
Rename:
- host.hello -> workspace.hello;
- host.heartbeat -> workspace.heartbeat;
- host.sync -> workspace.sync;
- host status/update -> workspace status/update.

Assignment messages remain assignment-centric.

### Authentication
Runtime credential authenticates exactly one execution Workspace.

Remove:
- connection Workspace tenant parameter;
- authorizedWorkspaceIds;
- Host multi-Workspace bindings.

### Gateway
- `HostGateway` -> `WorkspaceGateway`;
- one Durable Object identity per execution Workspace;
- stale socket fencing retained;
- heartbeat/reconnect retained;
- assignment replay retained.

### Tests
- wrong Workspace runtime token;
- revoked Workspace;
- stale socket;
- reconnect;
- sleep/wake;
- protocol mismatch;
- assignment for ungranted Project rejected by Cloud before dispatch.

### Exit criteria
The machine connection has no collaborative Workspace concept.

---

## V5-7 — Migrate Worker desired state to execution Workspaces

### Goal
Keep v4's strong Worker lifecycle but attach it directly to the new Workspace.

### Keep
- signed packages;
- immutable versions;
- desired state;
- reconciliation;
- health;
- rollback;
- garbage collection;
- process isolation.

### Rename persistence/API
- host desired workers -> Workspace desired Workers;
- host installations -> Workspace Worker installations.

### Authorization
Only Workspace owner manages installed/enabled Workers initially.

Project collaborators cannot install/remove/update Workers.

### Tests
- owner enables Worker;
- collaborator cannot;
- same Worker serves multiple Projects;
- active assignment during update;
- rollback;
- Workspace offline/reconnect.

### Exit criteria
Worker lifecycle is entirely Workspace-owner controlled.

---

## V5-8 — Refactor AI Accounts to User ownership + Project grants

### Goal
Remove Workspace-team credential semantics.

### Model
AI Account:
- owner User;
- Worker;
- optional execution Workspace storage location;
- auth/readiness;
- sharing mode.

### Grants
Add explicit:
- Account -> Project;
- optionally Account -> selected Project members.

### Rules
- Workspace Grant never implies Account grant;
- Project membership never implies Account grant;
- secret is never revealed to consumers;
- provider sharing restrictions remain authoritative.

### Local setup
If a collaborator wants their AI Account available on another owner's Workspace:
- create setup intent;
- Workspace owner approves local setup;
- secret remains local;
- Project grant determines use.

### Tests
- owner's private Account;
- Project-shared Account;
- selected member;
- revoke;
- provider private-only policy;
- local Account missing on target Workspace;
- removal from Project revokes use.

### Exit criteria
AI identity/payment authorization is independent from execution capacity.

---

## V5-9 — Implement Workspace Project Grants

### Goal
Create the actual Project-to-execution bridge.

### API operations
Workspace owner:
- list Projects using Workspace;
- grant Workspace to Project;
- update grant scope;
- suspend/revoke grant.

Project owner:
- request/add an owned Workspace;
- list effective execution Workspaces.

Collaborator:
- contribute one of their own Workspaces with explicit confirmation;
- cannot alter another owner's grant.

### UI
Project -> Execution -> Workspaces.

Workspace -> Project access.

### Safety
Full Workspace grant:
- recent step-up;
- explicit warning;
- audit event.

### Tests
- owner grants;
- collaborator contributes own;
- collaborator cannot grant owner's;
- revoke during queued work;
- active assignment keeps immutable snapshot but cancellation policy is applied;
- path scope.

### Exit criteria
Projects can use execution infrastructure without global sharing.

---

## V5-10 — Rewrite scheduler around Project execution resources

### Goal
Resolve execution exclusively from Project resources.

### Selection pipeline
1. authorize requester on Project;
2. load active Workspace Grants;
3. filter online Workspaces;
4. filter ready Workers/capabilities;
5. resolve Account requester may use;
6. compute effective permissions;
7. apply capacity;
8. apply model/provider independence;
9. apply budget/cost;
10. persist immutable target;
11. dispatch.

### Remove
- Workspace tenant filtering;
- Host Workspace binding checks;
- Workspace role `host.use`;
- configured Worker legacy code.

### Tests
- two contributors' Workspaces;
- unavailable owner's Workspace;
- no Account available;
- independent providers;
- grant capability restriction;
- concurrency;
- budget;
- explicit Workspace override;
- Auto selection.

### Exit criteria
Every Assignment can explain exactly why a Workspace/Worker/Account was eligible.

---

## V5-11 — Enforce Project scope inside Workspace runtime

### Goal
Make Project sharing safe even when Workers have powerful tooling.

### Runtime
Before Worker launch:
- validate Assignment grant snapshot;
- resolve registered repository/path mapping;
- build constrained working directory;
- validate permissions against Worker manifest;
- inject only required secrets;
- deny unauthorized path/system capability.

### Filesystem
Protect against:
- `..` traversal;
- symlink escape;
- absolute paths outside grant;
- worker-supplied alternate working directory.

### Shell/process
Policy must distinguish:
- repository-local commands;
- arbitrary shell;
- system administration.

### Tests
- malicious path;
- symlink;
- shell escape;
- undeclared network;
- credential exfiltration attempt fixture;
- full Workspace grant positive path.

### Exit criteria
A Project collaborator cannot escape the Workspace Grant through Worker configuration.

---

## V5-12 — Refactor Project collaboration UX

### Goal
Make Project sharing the obvious collaboration workflow.

### Project pages
- Overview;
- Chats;
- Runs;
- Artifacts;
- Members;
- Execution;
- Settings.

### Add
- Share Project;
- pending invitations;
- role management;
- member removal;
- Project audit events;
- execution summary.

### Remove
- Workspace Members;
- Workspace Invitations;
- Workspace Permissions;
- Workspace Audit collaboration screens.

### Tests
- owner flow;
- collaborator flow;
- viewer flow;
- invitation acceptance;
- removal;
- responsive/mobile;
- keyboard/accessibility.

### Exit criteria
A user never needs to understand a tenant Workspace to collaborate.

---

## V5-13 — Rebuild Workspaces UI

### Goal
Make the execution environment understandable as a product.

### List view
Show:
- name;
- online/offline;
- OS/runtime;
- Workers;
- current load;
- Project Grants;
- last seen;
- update state.

### Detail
- Overview;
- Workers;
- AI Accounts/local actions;
- Project access;
- repositories/permissions;
- activity;
- settings.

### Primary actions
- Add Workspace;
- rename;
- update;
- revoke;
- grant to Project.

### Exit criteria
The old Hosts UI is fully replaced rather than merely relabeled.

---

## V5-14 — Rework realtime scopes

### Goal
Remove Workspace tenant subscriptions while preserving efficient updates.

### Browser realtime
Subscriptions:
- user;
- Project;
- Chat;
- Run;
- owned execution Workspace when relevant.

### Events
Project events carry Project ID.

Workspace runtime events carry execution Workspace ID.

Assignment events carry both Project and execution Workspace correlation where useful.

### Reconnect
Cursor/gap recovery scoped to affected read model.

### Tests
- two Projects in separate tabs;
- collaborator removed while connected;
- Workspace goes offline;
- grant revoked;
- run streaming;
- reconnect gap.

### Exit criteria
Realtime authorization matches v5 ownership boundaries.

---

## V5-15 — Usage, budgets and audit migration

### Goal
Preserve accounting quality after removing collaborative Workspace.

### Usage dimensions
Record:
- requester;
- Project;
- execution Workspace;
- Workspace owner;
- Worker;
- AI Account;
- Account owner;
- provider/model;
- tokens;
- duration;
- cost.

### Budgets
Initial scopes:
- Project;
- Run;
- AI Account.

Optional owner Workspace capacity/cost policy remains separate.

### Audit
Separate:
- account/security audit;
- Project audit;
- Workspace-owner execution/security audit.

### Exit criteria
No accounting report depends on old Workspace tenancy.

---

## V5-16 — Remove obsolete v4 Workspace infrastructure

### Goal
Delete compatibility after all v5 paths are live.

### Delete
- collaborative Workspace models;
- Workspace switcher;
- Workspace settings feature;
- Workspace membership/invitation routes;
- Workspace role permission map;
- `host_workspace_bindings`;
- multi-Workspace Host connection logic;
- old Workspace headers;
- old v4 docs from normative references.

### Search gate
Active source must contain no architecture-level use of:
- `WorkspaceMembership`;
- `WorkspaceRole`;
- `host_workspace_bindings`;
- `host.bind_workspace`;
- `x-conclave-workspace-id`;
- product-facing `Host`.

Historical docs may remain explicitly marked historical.

### Exit criteria
There is one architecture, not v4 plus compatibility.

---

## V5-17 — Clean-room acceptance

### Goal
Validate v5 from an empty environment.

### Solo path
1. sign in;
2. user has zero Projects/Workspaces initially;
3. Add Workspace;
4. pair Conclave Workspace app;
5. enable Codex Worker;
6. connect private Account;
7. create Project;
8. grant own Workspace;
9. create Chat;
10. execute and verify result.

### Collaboration path
1. owner invites collaborator to Project;
2. collaborator sees Project but not owner's other Projects;
3. collaborator sees only execution resources granted to Project;
4. collaborator cannot manage owner's Workspace;
5. collaborator executes using an authorized Project Account or own allowed Account;
6. owner revokes Workspace Grant;
7. further execution is denied.

### Multi-owner infrastructure path
1. collaborator contributes their own Workspace;
2. scheduler can use either grant;
3. removing collaborator removes their Project access;
4. policy determines whether their Workspace Grant is automatically revoked (recommended yes).

### Exit criteria
All flows work without manual DB changes or old Workspace concepts.

---

## V5-18 — UI/UX and security acceptance

### UX acceptance
- Workspace clearly means execution environment;
- Project clearly means collaboration;
- no ambiguous sharing copy;
- dangerous full Workspace scope is unmistakable;
- one-click path from Project to granted execution resources;
- excellent empty states.

### Security acceptance
- Project ID substitution;
- runtime token substitution;
- grant bypass;
- path escape;
- Account grant bypass;
- stale membership;
- revoked runtime;
- forged Assignment correlation;
- Worker permission escalation;
- step-up for sensitive actions.

### Accessibility
- keyboard;
- screen reader;
- contrast;
- reduced motion;
- focus order;
- live Run announcements.

### Exit criteria
Independent review finds no conceptual or authorization ambiguity between Project, Workspace, Worker and AI Account.

---

## V5-19 — Architecture v5 release gate

### Required
- full TypeScript/Dart/Flutter suites green;
- schema/protocol generation green;
- clean-room acceptance green;
- macOS Workspace app acceptance;
- Windows/Linux compile;
- Cloudflare production preflight;
- dependency/security audit;
- architecture search guard;
- docs consistency;
- no obsolete Workspace tenant UI.

### Final mental model test

A new user should be able to explain Conclave correctly:

> I create Projects and invite people to them. I add Workspaces from my computers or servers. A Project can use selected Workspaces. Each Workspace has Workers. AI Accounts are granted separately.

If the product requires a longer explanation, v5 is not finished.
