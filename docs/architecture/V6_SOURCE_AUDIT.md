# Architecture v6 Source Audit

**Repository:** `nohainc/conclave`  
**Reviewed:** 2026-09-24  
**Baseline:** main after Architecture v5 implementation  
**Target:** [ARCHITECTURE_V6.md](ARCHITECTURE_V6.md)

## V6-0 implementation status

The first convergence slice is now implemented on the working baseline:

- the app no longer exposes a global Workspace selector or Workspace settings/invitation screen;
- Workspace enrollment uses the execution-Workspace `/enrollments` route;
- collaborative Workspace invitation/member routes and legacy Host enrollment aliases are no longer routed;
- assignment dispatch rejects requests without Project/requester context and sends valid requests through the v5 Project scheduler;
- `scripts/verify-v6-convergence.mjs` is the source-level guard for these removals.
- `apps/cloud/migrations-v6/0001_conclave_v6.sql` defines the clean Workstream/workflow/checkpoint/lease baseline and v6 correlation columns;
- SQLite migration tests cover clean apply, foreign keys, one active checkout, one active lease, and checkpoint parents.

The remaining security and persistence cleanup below is intentionally tracked as follow-up V6-0 work; no Workstream implementation should depend on those legacy paths.

## 1. Executive assessment

The v5 implementation is directionally correct and contains strong reusable primitives, but it is not yet fully converged on the normative v5 architecture.

v6 should therefore begin with a conformance cleanup before adding Workstreams.

The most important current findings are:

1. Flutter still keeps an active Workspace selector/state and Workspace creation/settings UX that belongs to the old collaborative Workspace model.
2. Security still contains v4 WorkspaceRole/WorkspaceSecurityContext compatibility and old Host/Workspace authorization helpers.
3. Cloud handlers still contain large v4 routes and SQL referencing collaborative `workspaces`, `workspace_memberships`, old Host enrollment/binding and Workspace-scoped Chats/Runs.
4. Assignment dispatch still has a legacy fallback path using old configured Worker/Agent tables when v5 Project fields are absent.
5. Core `entities.ts` still contains old Workspace/Project/Chat/ExecutionHost shapes beside canonical v5 entities.
6. Chat message creation can still infer intent and automatically start/resume Goals/Runs.
7. Runtime repository resolution still points execution at the registered repository checkout. The safe Git worktree primitive exists and is tested, but is not yet promoted into orchestration.
8. Workstream does not exist in source today.

These are not reasons to rewrite. They identify the safest v6 migration order.

## 2. Strong v5 assets to keep

### Domain/security
- `packages/core/src/v5-entities.ts`;
- ProjectMembership;
- WorkspaceProjectGrant;
- ProjectAccountGrant;
- immutable ResolvedExecutionTarget;
- permission intersection logic;
- path mapping validation.

### Scheduler
- `apps/cloud/src/v5-scheduler.ts`;
- Project-first resource selection;
- Account authorization independence;
- capacity filtering;
- Workspace Grant filtering;
- selection explanation snapshots.

### Runtime
- signed Worker package lifecycle;
- desired-state Worker reconciliation;
- Worker child-process isolation;
- assignment journal;
- stale/replay protection;
- `SafeWorkspace`;
- `SafeCommandRunner`;
- `GitRepository`;
- tested `createWorktree/removeWorktree`;
- path/symlink containment;
- permission snapshot validation.

### Collaboration
- Project owner/collaborator/viewer roles;
- Project invitations;
- Project member administration;
- Project page tabs and Share Project flow.

### Infrastructure
- Better Auth;
- Cloudflare Workers/Workflows/Durable Objects/D1/R2;
- realtime publisher;
- Goal/Run/Task/Attempt;
- findings/artifacts/verifications;
- usage accounting.

## 3. v5 conformance gaps to close first

## 3.1 Flutter active Workspace state is still old-model behavior

`apps/app/lib/src/studio/studio_app.dart` still contains:
- `selectedWorkspaceId`;
- `activeWorkspaceId`;
- `_loadWorkspaces()`;
- `_switchWorkspace()`;
- `_createWorkspace()`;
- `setActiveWorkspace()`;
- Workspace selector/menu;
- Workspace settings/invitations navigation.

The current Workspace menu copy says:
> Projects, people and execution resources

That conflicts with v5:
> Workspace is execution, Project is collaboration.

### v6 action

Before Workstream UX:
- remove browser active-Workspace selection;
- list owned execution Workspaces as resources, not application context;
- Add Workspace means enroll/create execution runtime, not tenant creation;
- remove collaborative Workspace settings/invitations;
- route Projects independently.

## 3.2 Security still carries dual v4/v5 models

`packages/security/src/index.ts` still defines:
- WorkspaceRole;
- WORKSPACE_ROLE_PERMISSIONS;
- WorkspaceSecurityContext;
- v4 `resolveWorkspaceSecurityContext`;
- `authorizeHostWorkspaceBinding`;
- `authorizeHostWorkspaceAction`;
- v4 CredentialProfile access records.

v5 logic is layered through `authorizationModel === "v5"`.

### v6 action

Make v5/v6 the only active model:
- replace WorkspaceSecurityContext with UserSecurityContext;
- delete v4 role inheritance;
- delete v4 Workspace resolver;
- delete old Host/Workspace binding authorization;
- keep Project membership helpers and Workspace owner helpers;
- keep Account use helper under v5 schema only.

This should land before new Workstream permissions.

## 3.3 Cloud handlers still mix schemas

`apps/cloud/src/routes/handlers.ts` contains both:
- v5 Project authorization imports; and
- old collaborative Workspace routes/SQL.

Observed old paths include:
- list/create collaborative Workspace;
- Workspace members/invitations;
- old Host enrollment routes;
- Host Workspace binding;
- old Workspace-scoped Chat/Goal/Run SQL;
- audit writes to old `audit_log.workspace_id`.

### v6 action

Split active handlers by domain and remove old paths:
- auth;
- projects;
- workspaces (execution);
- workers;
- accounts;
- workstreams;
- runs;
- artifacts;
- usage.

Do not add Workstream handlers to the existing giant mixed file without cleanup.

## 3.4 Assignment dispatcher still has a legacy branch

`apps/cloud/src/assignment-dispatcher.ts` has:
- modern `dispatchV5ProjectAssignment`; and
- fallback legacy dispatch through configured Worker/Agent tables.

### v6 action

Remove the legacy fallback before Workstream execution.

Every new Assignment must have:
- projectId;
- requesterUserId;
- Workstream/Work Request context when applicable.

There should be one scheduler path.

## 3.5 Core still has two vocabularies

`packages/core/src/entities.ts` still contains:
- Workspace tenant entity;
- Project.workspaceId;
- Chat.workspaceId;
- ExecutionHost;
- legacy Worker/Agent concepts.

`v5-entities.ts` contains the correct newer model.

### v6 action

Promote current v5 entities into canonical Core and move/remove historical types.

New v6 Workstream entities should not be added beside another compatibility layer.

## 4. Current Chat execution coupling

`handleCreateChatMessage` currently:
- stores a user message;
- recommends/parses intent;
- decides intent;
- may call `startChatExecution`;
- may resume an existing Goal;
- emits execution metadata into message.

This is exactly the ambiguity v6 must remove.

### v6 action

Discuss endpoint:
- authorize Discuss permission;
- persist message;
- publish discussion event;
- no Goal/Run creation;
- no AI execution intent inference.

Work endpoint:
- validate Workstream execute permission;
- create explicit WorkRequest;
- snapshot Workflow;
- queue/run it.

The existing intent classifier may remain as a drafting aid for "Send to Work", but never as execution authority.

## 5. Runtime repository state

`WorkerAssignmentHandler._repositoryScopedPayload` resolves:
`repositoryId -> registered repository path`.

That means multiple mutating assignments can still receive the same checkout path.

### Existing strength

`runtime_capabilities.dart` already has:
- safe filesystem root;
- symlink defense;
- command allowlist;
- Git repository abstraction;
- tested worktree create/remove.

### v6 action

Introduce a Workspace-local WorkstreamCheckoutManager:
- managed checkout root;
- provision worktree;
- verify expected revision;
- acquire local lock/fencing token;
- produce assignment-specific checkout path;
- checkpoint;
- rollback/reset;
- archive.

Do not allow Cloud/Worker to send an arbitrary checkout path.

Cloud sends opaque:
- checkoutId;
- expectedRevision;
- fencingToken.

Runtime resolves it locally.

## 6. Workflow engine

Current `ConclaveRunWorkflow` hardcodes:
- intake;
- research;
- planning;
- implementation;
- verification.

This is useful history but too rigid for Workstream-specific work.

### v6 action

Keep Cloudflare Workflow as durable execution infrastructure, but drive it from versioned WorkflowDefinition data.

A Workflow runner should interpret a snapshot:
- steps;
- dependencies;
- stateless/stateful execution class;
- approval gates;
- completion criteria.

Do not encode provider/model names into Workflow definitions.

## 7. Project UX

Current Project page already has tabs:
- Overview;
- Chats;
- Runs;
- Artifacts;
- Members;
- Execution;
- Settings.

### v6 action

Change the primary shared unit:
- Chats -> Workstreams.

Project tabs:
- Overview;
- Workstreams;
- Runs;
- Artifacts;
- Members;
- Execution;
- Settings.

Existing Chats can be converted one-to-one into Workstreams for development data.

## 8. Prompt composer

Current normal Chat composer exposes:
- Worker;
- Model;
- Account;
- Workspace;
- quality.

This mixes human conversation and execution.

### v6 action

Split UI:
- DiscussComposer: text + references only.
- WorkComposer: Work Request + Workflow + optional advanced execution controls.

This is a meaningful simplification.

## 9. Workspace/Project grants

v5 WorkspaceProjectGrant remains correct.

v6 does not replace it.

A Workstream Primary Workspace stores a reference to an active WorkspaceProjectGrant.

The Workstream cannot bypass Project execution policy.

## 10. Workstream permission model

Do not create an independent ACL universe.

Use:
1. Project role as outer bound.
2. Workstream policy as narrowing.
3. Account grants remain separate.
4. Workspace Grants remain separate.

Recommended checks:
- canViewWorkstream;
- canDiscussWorkstream;
- canExecuteWorkstream;
- canManageWorkstream.

No generic role inheritance from execution Workspace.

## 11. Scheduler changes

`v5-scheduler.ts` remains the base.

Add inputs:
- workstreamId;
- workRequestId;
- workflowStep;
- executionClass;
- primaryWorkspaceGrantId;
- checkoutId;
- lease/fencing data;
- base checkpoint/revision.

For stateless_read:
- v5 Auto selection remains valid.

For stateful_workstream:
- Workspace is fixed to Workstream Primary Workspace;
- grant is fixed;
- checkout/lease required;
- only Worker/Account/model selection remains dynamic.

## 12. Concurrency

Current v5 concurrency is Workspace-Grant capacity, not mutable-checkout protection.

v6 needs a second dimension:
- Workspace capacity;
- Workstream mutation exclusivity.

The Workstream coordinator prevents two stateful Runs from mutating one checkout even if Workspace capacity is >1.

## 13. Durable Object design

Use one WorkstreamExecutionCoordinator per Workstream.

Do not use it as the persistent database.

D1 stores:
- Work Request states;
- lease;
- checkout;
- checkpoint.

DO stores/reconstructs:
- active lease;
- queue wakeups;
- fencing counter/cache;
- realtime coordination.

On startup/reconnect it reconciles D1 before dispatch.

## 14. Migration of existing development Chats

Suggested one-time dev converter:
- each Chat -> one Workstream;
- title -> Workstream title;
- user/conclave conversational messages -> Discuss where appropriate;
- historical status/run messages -> Work activity references;
- Goals/Runs keep original IDs and gain workstreamId where possible.

If clean reset is simpler, prefer clean v6 fixtures.

## 15. Tests required by v6

### V6-4 Discuss / Work boundary

- Discussion messages are reference-only and never create Goals or Runs.
- Work Requests are the explicit execution entry point, require Project execute authorization, validate a workflow version, record the requester, and create a correlated Run.
- Generic Chat message handling has no intent-orchestration or automatic-resume path.

### V6-5 Workstream authorization

- `canViewWorkstream`, `canDiscussWorkstream`, `canExecuteWorkstream`, and `canManageWorkstream` are pure Core policy functions.
- Project membership is the outer bound; Workstream policy can only narrow selected users, roles, and view/discuss/execute permissions.
- Project owners retain override, viewers cannot be elevated, and the assigned Workstream Lead may manage the Workstream while remaining subject to Project membership.
- Cloud Discuss and Work Request routes re-read Project membership and the stored Workstream policy before allowing access.

### V6-6 Workstream Project UX shell

- Project navigation presents Workstreams as the focused unit instead of a Chats tab.
- Workstream deep links use `/projects/:projectId/workstreams/:workstreamId`.
- The shell exposes Discuss and Work tabs with Brief, Lead/status, Primary Workspace, Checkpoint, and queue summaries.
- Creation and archive controls are role-gated; execution remains a disabled preview until the Workstream runner lands.

### V6-7 Runtime managed checkout manager

- `WorkstreamCheckoutManager` is the only runtime mapping from opaque Cloud checkout IDs to local paths.
- Checkout paths are generated from identifiers under the managed `.conclave/workstreams` root; assignments cannot provide absolute paths or branches.
- Provisioning is idempotent, branch/revision metadata is verified on reopen, operations use per-checkout file locks, and recovery/checkpoint/archive operations reuse `SafeWorkspace` and `GitRepository`.

### V6-8 Checkout provisioning control plane

- Cloud provisions only after resolving the Workstream Primary Workspace, active Workspace Project Grant, repository, and online status.
- `checkout.provision`, `checkout.status`, `checkout.recover`, and `checkout.archive` are part of the Workspace Runtime protocol.
- Runtime status updates persist the ready/stale/deleted state and head revision, and publish `workstream.checkout.status` realtime events.
- Retry uses the existing active checkout record and opaque ID; grant revocation, offline Workspaces, missing repositories, and invalid base revisions fail explicitly.

### Domain
- Workstream Lead must be Project owner/collaborator;
- viewer cannot gain execute through Workstream;
- Workstream policy only narrows;
- Workflow version immutability;
- checkpoint chain integrity.

### Cloud
- Discuss never creates Run;
- Work Request always records requester;
- FIFO stateful queue;
- stateless concurrency;
- stale fencing rejection;
- Primary Workspace enforcement;
- Account authorization;
- grant revoked while queued.

### Runtime
- managed worktree path cannot escape;
- duplicate checkout provisioning idempotent;
- expected revision mismatch;
- stale fencing token;
- local lock;
- failed Run rollback;
- dirty tree recovery;
- checkpoint creation;
- two Workstreams execute concurrently on one machine.

### UI
- Discuss has no execution controls;
- Work requires explicit Run;
- Send to Work does not auto-run;
- viewer sees Work but cannot execute;
- queued state visible;
- needs-input lock state visible;
- Work result summary links back into Discuss.

## 16. Recommended migration order

1. v5 conformance cleanup.
2. canonical v6 domain.
3. clean schema.
4. Discuss/Work API split.
5. Workflow definitions.
6. checkout manager.
7. execution lease/coordinator.
8. scheduler integration.
9. checkpoint/recovery.
10. Account/sponsor policy.
11. Workstream UI.
12. migration/cleanup.
13. acceptance.

The most important sequencing rule:

> Do not build Workstream execution on top of the current generic Chat execution path or legacy assignment fallback.
