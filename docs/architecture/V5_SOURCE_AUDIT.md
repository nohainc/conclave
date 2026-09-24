# Architecture v5 Source Audit

**Repository:** `nohainc/conclave`
**Reviewed:** 2026-09-24
**Baseline:** main / Architecture v4 implementation
**Target:** [ARCHITECTURE_V5.md](ARCHITECTURE_V5.md)

## 1. Executive assessment

The repository does not need a rewrite.

The strongest v4 components should be retained:
- Better Auth;
- Goal/Run/Task/Attempt orchestration;
- immutable Assignments;
- Cloudflare Workflows/Durable Objects;
- realtime event publication;
- signed Worker packages;
- WorkerManager reconciliation;
- Worker child-process isolation;
- machine credential/pairing mechanics;
- assignment journal/replay;
- local secure credential storage;
- artifacts/findings/verifications;
- Project membership table.

The main architectural debt for v5 is concentrated in four areas:

1. collaborative Workspace tenancy;
2. Host <-> Workspace binding authorization;
3. Workspace-scoped credential ownership/grants;
4. product/UI terminology and navigation.

## 1.1 V5-1 canonical Core vocabulary

The provider-independent Core now defines the v5 entities in
`packages/core/src/v5-entities.ts`:

- `ExecutionWorkspace` with exactly one `ownerUserId`;
- `WorkspaceRuntimeIdentity`, `WorkspaceSession`, and `WorkspaceEnrollment`;
- `WorkspaceWorkerInstallation`;
- `WorkspaceProjectGrant`;
- `ProjectMembership` and `ProjectInvitation`;
- `ProjectAccountGrant`;
- v5 `ResolvedExecutionTarget` and immutable `WorkerAssignment` snapshots.

The v5 authorization helpers keep Project collaboration separate from runtime
execution and Account use. Cross-user execution requires an active
`WorkspaceProjectGrant`; Account use requires an independent
`ProjectAccountGrant`; effective permissions are the intersection of Project,
grant, Worker, Workspace-local, and Project-policy permissions.

The old v4 entity exports remain available only as migration support and are
not the canonical v5 names. New Core code must use the v5 surface.

V5-2 adds the provider-independent grant contract to that surface. A grant
now carries repository/path mappings, Worker IDs and capabilities, allowed
permissions, network policy, concurrency, optional budget, expiry, and the
`project_repository`, `selected_paths`, or `full_workspace` scope. Core emits
one immutable `EffectiveWorkspacePermission` snapshot after applying the
intersection of Project membership, grant, Worker manifest, Workspace-local,
and Project-policy permissions. `full_workspace` requires step-up
verification; path and symlink containment are checked before execution.

## 2. Current -> v5 mapping

| Current source/concept | v5 action |
| --- | --- |
| collaborative `workspaces` table | remove as tenant concept |
| `workspace_memberships` | replace with Project memberships only |
| `workspace_invitations` | replace with Project invitations |
| active Workspace browser state | remove |
| `x-conclave-workspace-id` | remove |
| Workspace selector/sidebar | remove |
| Workspace settings feature | remove/redistribute |
| v4 Host | rename to execution Workspace |
| `hosts` table | replace with `execution_workspaces` |
| `host_workspace_bindings` | delete |
| Host multi-Workspace socket authorization | delete |
| Host enrollment/session/release | rename to Workspace runtime equivalents |
| `host_worker_installations` | `workspace_worker_installations` |
| `host_desired_workers` | `workspace_desired_workers` |
| Host Gateway | Workspace Gateway |
| Conclave Host desktop app | Conclave Workspace desktop app |
| `project_memberships` | promote to primary collaboration model |
| Project role lead | migrate to owner/collaborator or explicit ownership field |
| `credential_profiles.workspace_id` tenant meaning | remove/refactor to owner + optional execution Workspace location |
| Workspace-owned CredentialProfile | remove from initial v5 model |
| `credential_grants` Workspace/role grants | replace with Project/selected-member Account grants |
| `worker_assignments.workspace_id` tenant meaning | replace with Project + execution Workspace + grant snapshot |
| Workers | keep |
| Worker versions/catalog | keep |
| Worker process model | keep |
| Assignment permissions | strengthen and derive from WorkspaceProjectGrant |

## 3. Cloud security package

### V5-4 active authorization boundary

The browser-facing authorization path now resolves a v5 context from:

```text
User ownership + current Project memberships
```

It does not accept a Workspace ID header or URL selector. Project membership
is re-read for protected Project requests, so removing a member invalidates
access during an existing browser session. Workspace operations use explicit
owner checks, and Project deletion uses the Project owner check.

The historical `WorkspaceSecurityContext` shape remains as a compatibility
carrier for the v4 runtime while route and persistence surfaces migrate; its
v5 instances have no selected Workspace and no Workspace-role inheritance.

### Current

`packages/security/src/index.ts` is explicitly built around:

```text
User -> Workspace -> Project
```

It defines:
- Workspace roles: owner/admin/member/viewer;
- Workspace role permission sets;
- Project roles;
- `WorkspaceSecurityContext`;
- `resolveWorkspaceSecurityContext`;
- `host.use`;
- Host authorization through active `host_workspace_bindings`;
- Credential authorization tied to Workspace ID.

### v5 action

This package requires a focused redesign, not incremental additions.

Target context:

```ts
type UserSecurityContext = {
  userId: string;
  user: AuthenticatedUser;
  sessionId: string;
  clientType: ClientType;
}
```

Project authorization should resolve separately from Project membership.

Resource ownership helpers:
- `authorizeProject(...)`;
- `authorizeWorkspaceOwner(...)`;
- `authorizeWorkspaceGrantUse(...)`;
- `authorizeAccountUse(...)`.

Delete:
- `WorkspaceRole`;
- `WORKSPACE_ROLE_PERMISSIONS`;
- `resolveWorkspaceSecurityContext`;
- `authorizeHostWorkspaceAction`;
- `authorizeHostWorkspaceBinding`.

## 4. D1 v4 schema (historical)

### High-impact tables

The historical `apps/cloud/migrations-v4/0001_conclave_v4.sql` made `workspace_id` foundational across:
- Projects;
- Chats;
- Goals;
- Runs;
- artifacts;
- findings;
- verifications;
- events;
- budgets;
- usage;
- audit;
- credential profiles;
- assignments.

Since Conclave is pre-production, rewriting the baseline is safer than carrying tenant compatibility.

### v5 baseline

The clean v5 baseline is now `apps/cloud/migrations-v5/0001_conclave_v5.sql`.
It is a fresh development/provisioning baseline rather than an edit of the v4
migration. It has no compatibility triggers or views.

Core ownership:

```text
users
projects(owner_user_id)
project_memberships
project_invitations

execution_workspaces(owner_user_id)
workspace_enrollments
workspace_sessions
workspace_releases
workspace_worker_installations
workspace_desired_workers
workspace_project_grants

credential_profiles(owner_user_id, optional execution_workspace_id)
project_account_grants
```

Project-derived tables should reference Project directly.

## 5. Cloud route handlers

`apps/cloud/src/routes/handlers.ts` contains extensive Workspace-scoped routes:
- Workspace CRUD;
- members/invitations;
- Host enrollment;
- Host listing/detail;
- Host Workspace binding;
- Worker management;
- Account management;
- task dispatch.

### Remove
- collaborative Workspace CRUD from user product API;
- member/invitation routes under Workspace;
- bind Host to Workspace;
- tenant Workspace arguments for Project APIs.

### Replace
User Workspaces:
- `GET /api/workspaces`;
- `POST /api/workspaces/enrollments`;
- `GET/PATCH/DELETE /api/workspaces/:workspaceId`;
- Worker desired-state under Workspace;
- Project grants under Workspace.

Projects:
- Project invitations/members;
- Project execution Workspace grants;
- Project Account grants.

The word Workspace remains in API, but now means execution Workspace.

## 6. Host Gateway

`apps/cloud/src/host-gateway.ts` is structurally valuable.

Keep:
- Durable Object per machine/runtime;
- stale socket fencing;
- machine token;
- heartbeat;
- reconnect;
- assignment dispatch;
- sync;
- assignment correlation validation.

Remove:
- `workspaceId` tenant during connection;
- `authorizedWorkspaceIds`;
- lookup through `host_workspace_bindings`;
- per-message collaborative Workspace binding checks.

Rename:
- HostGateway -> WorkspaceGateway;
- hostId -> workspaceId or executionWorkspaceId in the runtime protocol;
- host.hello -> workspace.hello.

The machine credential should authenticate exactly one execution Workspace.

## 7. Assignment dispatcher

The current main source has both modern v4 concepts and residual legacy selection code in places. v5 should use the modern v4 resolved-target logic as the base and delete remaining configured-worker compatibility.

### v5 selection input

Replace:
```text
workspaceId + task
```

with:
```text
projectId + requesterUserId + task
```

Resolve:
- Project membership;
- active WorkspaceProjectGrant;
- online execution Workspace;
- installed ready Worker;
- AI Account grant;
- effective permissions;
- capacity/budget/independence.

Persist:
- projectId;
- executionWorkspaceId;
- workspaceProjectGrantId;
- immutable permission snapshot.

## 8. Conclave AX Flutter app

### Current

`apps/app/lib/src/studio/studio_app.dart`:
- keeps `selectedWorkspaceId`;
- loads Workspace list;
- sends active Workspace to data source;
- shows selector when more than one;
- has Hosts, Workers, AI Accounts and Workspace Settings;
- Project pages are comparatively shallow.

`studio_stores.dart` includes `WorkspaceStore` and Agent/Host store.

### v5 action

Delete:
- active Workspace selection;
- `WorkspaceStore` tenant behavior;
- Workspace settings page;
- Workspace switcher.

Rename/refactor:
- Hosts navigation -> Workspaces;
- AgentStore -> WorkspaceStore (execution Workspace);
- Host models -> Workspace models.

Promote Project UX:
- Members;
- Execution;
- Runs;
- Artifacts;
- Settings.

The name collision means the old tenant Workspace model must be removed before or in the same phase that Host becomes Workspace.

## 9. Project UI

`apps/app/lib/src/features/projects/projects_pages.dart` currently provides:
- Project details;
- Chats;
- edit/archive/delete.

This is the best UI surface to expand for v5.

Add:
- Members;
- Execution;
- Workspaces;
- effective Workers;
- Account availability;
- permission scope;
- budget.

Do not add another global collaboration container.

## 10. Workspace settings UI

`features/workspace/workspace_settings_page.dart` currently contains:
- General;
- Members;
- Invitations;
- Permissions;
- Audit.

This feature is removed as a collaboration screen.

Redistribute:
- Members/Invitations -> Project;
- collaboration audit -> Project;
- personal/global security -> Profile & Security;
- execution Workspace settings -> new Workspace detail page.

## 11. Desktop Host app

`apps/host` should not be discarded.

Keep:
- lifecycle controller;
- local machine lock;
- diagnostics;
- logs;
- secure store;
- WorkerManager;
- assignment journal;
- Cloud connection;
- process supervision;
- update handling.

Rename product:
- Conclave Host -> Conclave Workspace.

The desktop app remains intentionally minimal.

It represents the runtime behind one execution Workspace.

## 12. WorkerManager

`apps/host/lib/worker_manager.dart` is one of the strongest reusable parts.

No conceptual redesign required.

Keep:
- immutable Worker versions;
- digest/signature verification;
- trust policy;
- permission validation;
- desired state;
- rollback;
- garbage collection;
- Worker process spec.

v5 enhancement:
- Worker launch permissions must intersect with WorkspaceProjectGrant snapshot;
- working directory/path scope must be assignment-specific.

## 13. HostCloudConnection

`apps/host/lib/cloud_connection.dart` currently carries:
- `workspaceId` collaborative tenant;
- `hostId`;
- authorized Workspace IDs;
- assignment correlation.

v5 should simplify to one execution Workspace identity.

Target:
```text
workspaceId
runtime token
Project/Run/Task correlation per Assignment
```

There is no list of tenant Workspace IDs.

## 14. Credential Profiles

Current v4 design solved shared-Host credentials through:
- Workspace owner type;
- User owner type;
- Workspace grants;
- role grants.

v5 is simpler.

Default:
- AI Account belongs to User;
- may be stored on one execution Workspace;
- may be granted to one Project;
- may optionally be restricted to selected members of that Project.

Do not inherit Account access from Project Workspace Grant.

## 15. Realtime

Current realtime envelope includes Workspace as tenant scope.

v5 should distinguish:
- Project events;
- execution Workspace owner events;
- account/user events.

Do not reuse one `workspaceId` field for both Project tenant and execution Workspace after the rename.

During protocol migration, use explicit `executionWorkspaceId` until ambiguity is impossible.

## 16. Docs and naming

Current top-level docs make Architecture v4 normative.

When v5 is accepted:
- update README;
- update ARCHITECTURE.md;
- update APPLICATIONS;
- mark v4 historical;
- supersede ADR-004 portions dealing with multi-Workspace Host sharing;
- add architecture guard.

## 17. Risk areas

### Highest risk
1. permission intersection and filesystem containment;
2. Account grant isolation;
3. migration of Cloud security context;
4. overloaded Workspace word during transition;
5. scheduler eligibility correctness.

### Moderate risk
- realtime scope migration;
- URL/API naming;
- desktop app package rename;
- clean schema reset;
- usage/audit dimensions.

### Low risk / reusable
- Worker package execution;
- Worker process isolation;
- Cloudflare runtime;
- Goal/Run/Task model;
- artifacts/verifications;
- authentication provider setup.

## 18. Recommended implementation order

Do not start by renaming Host in source.

The safest order is:

1. accept v5 architecture;
2. define new domain/grant/security rules;
3. define clean schema;
4. migrate human authorization to Project;
5. remove old tenant Workspace UI/state;
6. then rename Host -> Workspace;
7. migrate Gateway/protocol/runtime;
8. migrate Worker/Account ownership;
9. add Project Workspace Grants;
10. rewrite scheduler;
11. enforce runtime scopes;
12. finish UI/realtime/accounting;
13. delete compatibility;
14. clean-room acceptance.

This avoids having two different concepts named Workspace at the same time.

## 19. V5-5 product terminology

The active product surfaces now call the execution environment Workspace:
Flutter navigation and copy, desktop pairing and diagnostics, website copy and
diagrams, and the canonical execution route `/workspaces`. The parser still
accepts `/hosts` as a compatibility alias for old links.

The generated `host.*` protocol, `apps/host` source path, low-level Host Dart
types, and `conclave_host` package namespace remain migration aliases. They
are intentionally excluded from user-facing copy until the protocol and
package migration can be completed atomically.

## 20. V5-6 Workspace Runtime protocol and Gateway

The active machine connection uses `conclave.workspace-runtime-protocol`.
Lifecycle messages are `workspace.hello`, `workspace.heartbeat`, and
`workspace.sync`; assignment messages retain their assignment-centric names.
The connection presents one `workspaceRuntimeId` credential. Cloud derives
the single `executionWorkspaceId` from that credential and routes the
`WorkspaceGateway` Durable Object by execution Workspace, never by a
collaborative Workspace binding set.

The legacy generated Host protocol remains available only as a low-level
compatibility surface while generated bindings and package names are migrated.
The new Gateway retains stale-socket fencing, reconnect/session recording,
heartbeat handling, replay correlation, and rejects assignments whose active
Workspace Project Grant is absent, revoked, or expired.

## 21. V5-7 Workspace Worker desired state

Worker lifecycle state is now scoped to the execution Workspace. The active
desired-state boundary is `workspace_worker_desired_state`, and runtime health
and installation state is recorded in `workspace_worker_installations`. Only
the execution Workspace owner can enable, disable, or select a Worker version;
Project collaborators and viewers do not inherit Worker installation rights.

The Workspace runtime receives immutable signed package metadata during sync.
It reports installation and health observations back to Cloud, while Cloud
remains authoritative for desired state, version selection, assignment grants,
rollback, and garbage-collection eligibility. The same installed Worker can
serve multiple Projects when each assignment has its own valid Project
Workspace Grant and effective permission snapshot.

## 22. V5-8 User-owned AI Accounts

The active Account model is `ai_accounts`: ownership belongs to a User, while
`execution_workspace_id` is only the optional local storage placement. Account
use is granted through `project_account_grants`; neither Project membership nor
an active Workspace Project Grant is sufficient by itself. Selected-member
grants use `grantee_user_id`, while a null grantee grants the Account to the
Project subject to the provider's sharing policy.

Secrets remain outside Cloud responses and are never included in Account
metadata. Local setup uses `ai_account_setup_intents`: the Account owner
requests setup and the target Workspace owner approves it. Revocation and
expiry are checked at use time, so removing a Project Account Grant immediately
removes execution eligibility without changing Workspace capacity.

## 23. V5-9 Workspace Project Grants

`workspace_project_grants` is the explicit Project-to-execution bridge. Workspace
owners can list, create, update, suspend, and revoke grants for their own
Workspace. Project members can list effective grants, while Project owners and
collaborators may contribute only a Workspace they own; collaborators must send
an explicit contribution confirmation.

Grant scope is persisted with repository/path mappings, Worker and permission
allowlists, network, concurrency, budget, expiry, and step-up state. A
`full_workspace` grant requires a warning confirmation and a recent strong
authentication proof. Revoking a grant cancels only queued assignments; an
already-created assignment retains its immutable permission snapshot and is
subject to the runtime cancellation policy.

## 24. V5-10 Project-resource scheduler

The v5 dispatch path resolves execution from the Project rather than from a
Workspace tenant. It rechecks Project membership, active Workspace Grants,
online Workspace status, desired/ready Worker installation, Account ownership
or Project Account Grant, Worker capabilities, grant allowlists, concurrency,
provider/model constraints, budget, and the permission intersection before
persisting an assignment.

The persisted `permission_snapshot_json` contains both the immutable effective
permissions and a selection explanation covering the accepted Workspace,
Worker, Account, grant, and rejected alternatives. Explicit Workspace and
Worker overrides are filters within the Project resource set; they do not
bypass grants or readiness checks.

## 25. V5-11 Project scope inside the Workspace runtime

Before launching a Worker, the Workspace runtime validates the immutable
assignment permission snapshot against the installed Worker manifest. The
snapshot must identify the Project, execution Workspace, grant, requester,
scope, effective permissions, and path mappings; it cannot be replaced by
Worker-supplied configuration. Repository IDs are resolved through the local
registered-repository registry, and the resolved path is injected into the
assignment payload rather than accepting an arbitrary worker path.

The runtime rejects traversal, symlink escape, alternate working-directory
configuration, credential material in assignment input, and system
administration permissions. Worker process environments are allowlisted from
the manifest's required secret variables, while command execution remains
constrained by the local executable and argument policy. `full_workspace` is
accepted only as an explicit grant scope; it does not bypass snapshot,
manifest, process, or secret checks.

## 26. V5-12 Project collaboration UX

Project pages are the collaboration boundary. The active Project workspace
organizes Overview, Chats, Runs, Artifacts, Members, Execution, and Settings
under one Project navigation. Sharing, pending invitations, member roles, and
member removal are Project operations; the Project owner is the only role that
manages membership. Project collaborators can contribute to project work, and
viewers can read it, but neither role receives Workspace administration or
implicit Workspace access.

Execution remains a separate Project tab because it connects Project work to
explicit Workspace Project Grants. Workspace settings now describe only the
execution environment and no longer expose collaborative Members,
Invitations, Permissions, or Audit screens. Project collaboration actions are
recorded in `project_audit_log`.

## 27. V5-13 Workspace execution UI

The active Workspaces route is an execution-environment directory, not a Host
binding or tenant-membership screen. Each Workspace card presents runtime
status, OS and architecture, Worker count, current load, Project Grant count,
last-seen time, and update channel. Its detail view separates Overview,
Workers, local AI Accounts, Project access, repository and permission context,
activity, and lifecycle settings.

Workspace actions are Add, Rename, Update, Revoke, and Grant to Project. The
Project access view explains that Project Grants are explicit execution
bridges; Workspace membership or legacy binding state is not presented as a
collaboration permission.

## 28. V5-14 Realtime scopes

Browser realtime now uses typed `user`, `project`, `chat`, `run`, and
`execution_workspace` subscriptions. Project, Chat, and Run scopes authorize
through current Project membership; an execution Workspace scope authorizes
only its owner. The browser always maintains a user scope and adds focused
read-model scopes as navigation changes.

Project events carry `projectId`; runtime events carry the execution Workspace
identity; assignment and Run events retain both identifiers where available.
Durable cursor recovery is tracked per subscription scope, so activity in a
different Project does not create a false gap for the focused Project. A gap
resync reloads only the affected Project/read model or Workspace runtime view.
Legacy `{workspaceId}` subscription parsing remains only as a migration
compatibility path and is no longer emitted by the browser.
## 29. V5-15 Usage, budgets, and audit migration

V5 accounting is Project-scoped and records the execution dimensions needed to
explain every charge without consulting collaborative Workspace tenancy. Each
usage fact carries the requester, Project, execution Workspace, Workspace
owner, Worker, AI Account, Account owner, provider/model, token counts,
duration, cost, Run, and assignment correlation.

Budgets are independent scopes on the Project, Run, and AI Account dimensions.
The v5 scheduler checks all applicable active budgets before dispatch and
completion accounting is idempotent per assignment. Workspace-owner capacity
or cost policies remain execution policy, not Project accounting tenancy.

Audit history is separated by authority boundary:

- account and authentication security events remain in the auth audit stream;
- collaboration and Project actions remain in `project_audit_log`;
- execution Workspace owner actions and runtime security events belong in
  `execution_workspace_audit_log`.

The v5 usage report is exposed at `GET /api/projects/:projectId/usage` and
returns Project, Run, requester, execution Workspace/owner, Worker, Account/
owner, provider/model, token, duration, cost, and budget dimensions. The old
Workspace usage endpoint is retained only as a migration compatibility path;
new accounting reports must use the Project endpoint.

## 30. V5-17 Clean-room acceptance

The v5 persistence acceptance suite exercises the empty-environment ownership
path: a User owns a Project and an execution Workspace, a second User is added
only through Project membership, and two independently owned Workspaces can
be granted to the same Project. It also verifies that removing a contributor
revokes that contributor's active Project Grants under the recommended policy.

The scheduler suite covers automatic and explicit Workspace selection,
unavailable capacity, Worker capability restrictions, missing Accounts, and
viewer denial. Full browser/desktop sign-in, pairing, provider setup, and live
Worker execution remain release-environment checks because they require the
running Cloud, desktop runtime, and provider credentials.

## 31. V5-18 UI/UX and security acceptance

Acceptance coverage now treats the nouns as separate boundaries: Projects are
collaboration surfaces, Workspaces are execution environments, Workers are
installed execution capabilities, and AI Accounts are independently granted
provider identities. Project execution copy points to explicit Project Grants;
Workspace pages describe owner-controlled runtime state and local secrets.

The v5 security suites cover Project substitution, stale membership, owner-only
Workspace management, runtime-token substitution, revoked runtimes, forged
assignment correlation, grant and Account-grant bypass, path traversal and
symlink escape, Worker permission escalation, and full-Workspace step-up.
Existing Flutter widget coverage verifies Workspace empty/detail states and
Project collaboration navigation. Device-level screen-reader, contrast,
reduced-motion, and live Run announcement checks remain part of the desktop
release environment because they require Flutter platform semantics.
