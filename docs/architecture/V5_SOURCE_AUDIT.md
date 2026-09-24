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

## 4. D1 v4 schema

### High-impact tables

`apps/cloud/migrations-v4/0001_conclave_v4.sql` currently makes `workspace_id` foundational across:
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

### v5 recommendation

Create a new clean v5 baseline rather than editing the v4 migration in place during early phases.

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
