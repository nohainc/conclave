# Conclave AX Architecture v5 — Project-Centric Workspaces

> Historical vocabulary note: ADR-010 and EW-0 supersede this document's
> user-facing AI Account/Credential Profile model. Those terms remain here to
> describe the v5 implementation baseline; the active product model is
> Execution → Workspaces + configured Workers, with credential state beneath
> Workers.

**Status:** Normative
**Date:** 2026-09-24
**Supersedes:** Architecture v4 Host + Worker model

## 1. Executive decision

Architecture v5 changes the product boundary from shared tenant Workspaces to personal execution Workspaces plus shared Projects.

The user-facing execution model becomes:

```text
Conclave AX -> Conclave Cloud -> Workspace -> Worker
```

A **Workspace** is one execution environment backed by one enrolled machine/runtime. It contains the Workers, local credential material, repository/file permissions, runtime capacity, update state, and execution policy for that environment.

A **Project** is the collaboration, history, authorization, and execution-sharing boundary.

> **People share Projects. Projects are granted Workspaces. Workspaces provide Workers. Accounts decide whose external AI identity is used.**

The v4 collaborative Workspace concept is removed.

## 2. Why v5

Architecture v4 made Workspace both:
- a collaboration container; and
- the authorization boundary through which Hosts became usable.

That coupling is too broad for Conclave.

A v4 Workspace member can receive `host.use`. If a Host has a Worker with shell, filesystem, repository, browser, or tool permissions, Workspace membership can become indirect execution access to another person's machine.

That is not the mental model users expect from "join my Workspace".

The safer product model is:
- infrastructure is personal by default;
- collaboration is Project-scoped;
- execution infrastructure is shared only when explicitly granted to a Project;
- the grant itself defines what the Project may do on that Workspace.

## 3. Product vocabulary

### User-facing

- **Conclave AX** — main Flutter Web application.
- **Conclave Cloud** — cloud control plane, normally not emphasized in UI.
- **Workspace** — one execution environment backed by one enrolled machine/runtime.
- **Worker** — an installed AI/tool integration inside a Workspace.
- **AI Account** — external AI/provider identity usable by a Worker.
- **Project** — persistent work and collaboration boundary.
- **Chat** — conversation inside a Project.
- **Run** — one orchestrated execution.
- **Project Member** — a person invited to a Project.
- **Workspace Grant** — permission for a Project to use a Workspace.
- **Assignment** — immutable execution snapshot.

### Internal-only terms

Use internal names when precision is required:
- `WorkspaceRuntime` or `RuntimeIdentity` — machine-security identity behind a Workspace;
- `WorkspaceSession` — Cloud connection session;
- `CredentialProfile` — AI Account domain object;
- `ResolvedExecutionTarget` — resolved Workspace + Worker + Account + model/config;
- `WorkspaceProjectGrant` — Project-to-Workspace execution authorization.

Do not expose "Host" as a primary product noun after the v5 migration.

## 4. Core topology

```text
                         CONCLAVE AX
                         Flutter Web
                              |
                              | HTTPS + realtime
                              v
                        CONCLAVE CLOUD
          users / projects / collaboration / orchestration
                              |
                              | authenticated runtime protocol
                              v
                +-----------------------------+
                |          WORKSPACE          |
                | one execution environment   |
                | backed by one machine       |
                +-----------------------------+
                   |          |          |
                   v          v          v
                Codex      Claude      Git/Test
                Worker      Worker      Worker
                   |          |          |
                   +----------+----------+
                              |
                    AI / CLI / API / tools
```

A Project can use zero, one, or many Workspaces.

A Workspace can be granted to zero, one, or many Projects owned by or explicitly authorized by the Workspace owner.

## 5. Ownership model

### 5.1 User ownership

A User owns:
- Workspaces they enroll;
- private AI Accounts they create;
- Projects they create until ownership is transferred;
- personal preferences and personal usage views.

### 5.2 Project ownership

A Project has exactly one current owner and may have members.

Project roles:
- **owner**
- **collaborator**
- **viewer**

A future `manager` role may be added only if real product requirements justify it.

### 5.3 Workspace ownership

A Workspace has exactly one owner User in v5.

Joining a Project never:
- exposes a member's Workspaces;
- exposes a member's private AI Accounts;
- grants Workspace management;
- installs or removes Workers;
- changes local filesystem permissions.

## 6. Workspace semantics

A Workspace replaces the v4 user-facing Host.

Example:

```text
Workspace: Vitalii MacBook
  Status: online
  Runtime: macOS arm64
  Workers:
    - Codex
    - Claude Code
    - Git/Test
  Local permissions:
    - ~/dev/conclave
    - ~/dev/earth
  AI Accounts:
    - Vitalii Codex
    - Vitalii Claude
```

A Workspace is not a team container.

It is an execution environment.

### 6.1 One Workspace = one runtime identity

For v5, one Workspace maps to one enrolled runtime/machine identity.

Do not make a Workspace a cluster of machines yet.

If cluster/fleet behavior becomes necessary later, introduce an explicit higher-level pool abstraction instead of making Workspace ambiguous.

### 6.2 Runtime identity remains separate internally

Renaming Host to Workspace must not weaken machine security.

The runtime still needs:
- machine credential;
- pairing/enrollment;
- connection/session identity;
- heartbeat;
- update channel;
- local secure storage;
- process supervision;
- assignment journal;
- runtime recovery.

Those become Workspace runtime internals.

## 7. Worker model

A Worker remains an installable execution integration.

Examples:
- Codex;
- Claude Code;
- OpenAI;
- Anthropic;
- Gemini;
- Ollama;
- Web AI;
- Git/Test.

Workers are installed once per Workspace runtime/version.

Workers are not independently shared.

If a Project has an active Workspace Grant, eligible Workers installed in that Workspace may be used subject to:
- Project grant permissions;
- Worker manifest permissions;
- requesting user's AI Account authorization;
- capacity;
- Project policy;
- budget.

## 8. AI Account model

AI Accounts remain independent from Workspace sharing.

A Project Workspace Grant never automatically grants use of an AI Account.

An AI Account has:
- owner User;
- Worker;
- optional Workspace scope when the secret is stored locally;
- auth type;
- readiness;
- provider metadata;
- sharing policy.

Initial sharing modes:
- private;
- shared with Project;
- selected Project members.

Project-owned Accounts may be added later if needed, but v5 should prefer a clear human owner plus explicit Project grant unless billing/enterprise requirements prove otherwise.

### Security invariant

> Sharing a Workspace with a Project grants execution capacity, not credential use.

## 9. Project model

A Project is the primary collaboration boundary.

A Project owns:
- members and roles;
- Chats/messages;
- Goals;
- Runs;
- Tasks/Attempts;
- findings;
- verifications;
- artifacts;
- Project instructions;
- repository/context configuration;
- execution preferences;
- budgets;
- audit trail relevant to Project actions;
- Workspace Grants.

Example:

```text
Project: Conclave AX

Members
  Vitalii   owner
  Alex      collaborator
  Anna      viewer

Execution Workspaces
  Vitalii MacBook
    scope: project repository
    Workers: Codex, Claude, Git/Test

  CI Linux
    scope: repository + tests
    Workers: Codex, Git/Test
```

## 10. Project membership

### Owner

Can:
- manage Project settings;
- invite/remove members;
- change member roles;
- create/update Workspace Grants using Workspaces they own or are authorized to contribute;
- manage Project budgets;
- archive/delete Project;
- use Project execution resources.

### Collaborator

Can:
- read/write Project content;
- create Chats;
- start Runs;
- respond to approvals;
- use Project execution resources within the effective grant;
- contribute one of their own Workspaces to the Project after explicit confirmation.

Cannot by default:
- manage another person's Workspace;
- change another owner's Workspace Grant;
- use private AI Accounts;
- alter Workspace software/update state;
- delete Project.

### Viewer

Can:
- read Project content, results and artifacts permitted by Project policy.

Cannot:
- start execution;
- mutate Project content;
- use Workspace execution capacity.

## 11. Workspace Grants

The central new v5 object is `WorkspaceProjectGrant`.

It means:

> This Project may execute work on this Workspace under this bounded permission policy.

A grant contains:
- grant ID;
- Project ID;
- Workspace ID;
- Workspace owner User ID;
- granted by User ID;
- status;
- execution scope;
- allowed Worker IDs or capability policy;
- filesystem/repository scope;
- allowed permission set;
- optional network policy;
- concurrency limit;
- optional budget/cost policy;
- optional expiry;
- timestamps.

### 11.1 Default grant

For a software Project, recommended default:

```text
Scope: Project repository
Filesystem:
  read  yes
  write yes within repository
Shell:
  yes within Project execution
Git:
  yes
Network:
  Worker-defined / Project policy
System administration:
  no
Arbitrary home-directory access:
  no
```

### 11.2 Full Workspace grant

Advanced/high-trust option:

```text
Scope: Full Workspace
```

This must:
- require an explicit warning;
- require recent step-up authentication;
- be visibly marked in Project and Workspace UI;
- be auditable;
- never be the default.

### 11.3 Effective permissions

Effective assignment permissions are the intersection of:

```text
Project member permissions
∩ WorkspaceProjectGrant permissions
∩ Worker manifest permissions
∩ Workspace local policy
∩ Project execution policy
```

No layer may broaden permissions granted by another.

## 12. Project repository/context scope

The v5 model should make repository/path scope explicit.

A Workspace may know many local repositories.

A Project Workspace Grant maps the Project to:
- a registered local repository;
- a selected path;
- or a bounded set of paths.

Example:

```text
Project: Earth
Workspace: Vitalii MacBook
Repository mapping:
  github:nohainc/earth
    -> /Users/vitalii/dev/earth
```

The Worker receives the Project-specific resolved context, not unrestricted machine discovery.

## 13. Scheduling

The scheduler no longer begins with Workspace membership.

It begins with the Project:

```text
Task
  -> Project
  -> active Project Workspace Grants
  -> online eligible Workspaces
  -> ready Workers matching capabilities
  -> AI Accounts requester is authorized to use
  -> capacity / budget / independence / model policy
  -> ResolvedExecutionTarget
  -> Assignment
```

### ResolvedExecutionTarget

```text
Workspace
+ Worker
+ Worker version
+ AI Account
+ provider/model
+ Project grant
+ effective permissions
+ repository/path mapping
+ session policy
```

The resolved target is snapshotted into the Assignment and does not change after dispatch.

## 14. Assignment model

An Assignment snapshots:
- Project;
- Run/Task/Attempt;
- requesting User;
- Workspace;
- Workspace Grant;
- Worker;
- Worker version;
- AI Account;
- model/config;
- session policy;
- effective permissions;
- repository/path/context refs;
- timeout;
- idempotency key.

The Assignment must not depend on current UI state after creation.

## 15. Cloud <-> Workspace runtime protocol

The current Host protocol is retained structurally and renamed/refactored.

Cloud -> Workspace runtime:
- workspace.sync;
- worker desired state;
- account setup intents;
- assignment.start;
- assignment.cancel;
- runtime update.

Workspace runtime -> Cloud:
- workspace.hello;
- workspace.heartbeat;
- workspace.status;
- worker.status;
- account.status;
- assignment.ack;
- assignment.progress;
- assignment.result;
- assignment.error;
- runtime diagnostics metadata.

The Worker never connects directly to Cloud.

## 16. Realtime model

Realtime scopes become:
- User scope;
- Project scope;
- Workspace-owner scope;
- Run scope.

### User scope
For:
- Workspace online/offline;
- AI Account readiness;
- invitations;
- personal security events.

### Project scope
For:
- Chats;
- member changes;
- Workspace Grant changes;
- Runs;
- Tasks;
- findings;
- artifacts;
- approvals;
- shared execution state.

Workspace runtime events are projected into Project realtime only when they relate to a Project assignment/grant.

## 17. UI model

Primary navigation:

```text
Home
Projects

EXECUTION
Workspaces
Workers
AI Accounts
Usage

PROJECTS
  Conclave AX
  Earth
  Client X

Profile & Security
```

There is no global collaborative Workspace selector.

### 17.1 Workspaces page

Shows execution environments:

```text
Vitalii MacBook
Online · macOS arm64
3 Workers · 1 active Run
Used by: Conclave AX, Earth

Cloud Linux
Online · Linux x64
2 Workers · idle
Used by: Conclave AX
```

Primary action: **Add Workspace**.

This launches pairing/enrollment of a machine/runtime.

### 17.2 Workspace detail

Tabs/sections:
- Overview;
- Workers;
- AI Accounts requiring local action;
- Project access;
- Local permissions/repositories;
- Activity;
- Settings.

Project access shows grants created from this Workspace:

```text
Conclave AX     Project repository     Active
Earth           /dev/earth             Active
Client X        —                      Not granted
```

### 17.3 Project page

Recommended structure:

```text
Overview
Chats
Runs
Artifacts
Members
Execution
Settings
```

Execution includes:
- Workspaces;
- Workers/capabilities;
- AI Accounts available to requester;
- permissions;
- quality;
- budget.

### 17.4 Share Project

Primary collaboration action:

```text
Share Project
  Email
  Role: Collaborator / Viewer
```

No user-facing "share Workspace" collaboration flow exists.

## 18. Data model v5

Recommended clean pre-production schema direction.

### users

Keep Better Auth identity.

### projects

```text
projects
  id
  owner_user_id
  name
  description
  repository_id
  settings_json
  status
  created_at
  updated_at
```

Remove required collaborative `workspace_id`.

### project_memberships

```text
project_memberships
  id
  project_id
  user_id
  role: owner | collaborator | viewer
  status
  created_at
  updated_at
```

The owner may be represented both by `owner_user_id` and membership for query convenience, but invariants must guarantee exactly one owner.

### project_invitations

Replace Workspace invitations.

### execution_workspaces

Replace `hosts`.

```text
execution_workspaces
  id
  owner_user_id
  display_name
  hostname
  status
  runtime_version
  capabilities_json
  runtime_token_hash
  enrolled_at
  last_heartbeat_at
  revoked_at
  created_at
  updated_at
```

The product/API name should normally be `workspaces`; the table may use `execution_workspaces` to avoid ambiguity during migration.

### workspace_sessions

Replace host sessions.

### workspace_enrollments

Enrollment belongs to owner User, not a collaborative Workspace.

### workspace_releases

Replace host releases.

### workers / worker_versions

Keep global catalog.

### workspace_worker_installations

Replace host worker installations.

### workspace_desired_workers

Replace host desired workers.

### workspace_project_grants

New core v5 table.

### ai_accounts / credential_profiles

Refactor ownership from Workspace-centric to User-centric.

Suggested:
- `owner_user_id`;
- optional `workspace_id` for host-local storage location, where this now means execution Workspace;
- Worker ID;
- sharing policy;
- secret reference metadata.

### project_account_grants

Explicit permission to use an AI Account in a Project.

### worker_assignments

Replace `workspace_id` tenant meaning with:
- `project_id`;
- `execution_workspace_id`;
- `workspace_project_grant_id`;
- requester;
- Worker;
- AI Account;
- immutable effective permission snapshot.

## 19. Security invariants

1. A Workspace runtime authenticates as a machine/runtime, never as a human.
2. Every Workspace has one human owner in v5.
3. Joining a Project never grants access to a member's Workspaces.
4. A Project can execute on a Workspace only through an active WorkspaceProjectGrant.
5. A Project member cannot manage another user's Workspace merely because the Workspace is granted to the Project.
6. Workers inherit availability from their Workspace; Workers are not independently shared.
7. AI Account access is independent from Workspace access.
8. Private AI Accounts remain private unless explicitly granted.
9. Effective assignment permissions can only narrow, never widen, the Workspace Grant.
10. Worker processes receive only Assignment-scoped capabilities and secrets.
11. Project filesystem access is bounded by resolved repository/path mappings.
12. Full-Workspace execution is explicit, step-up protected, auditable, and non-default.
13. Assignment identity and effective permissions are immutable after dispatch.
14. Cloud remains the authoritative scheduler and authorization boundary.
15. Worker packages remain signed/verified before execution.

## 20. What v5 keeps from v4

Keep and reuse:
- Better Auth human authentication;
- Cloud-first authority;
- Cloudflare Workers/Workflows/Durable Objects/D1/R2;
- Worker package catalog/versioning;
- signed Worker package verification;
- Worker child-process isolation;
- Workspace runtime machine credential concept;
- pairing/enrollment mechanics;
- runtime heartbeat and reconnect;
- assignment journal/replay;
- desired-state Worker reconciliation;
- Credential Profile secure local storage primitives;
- Goal/Run/Task/Attempt model;
- artifacts/findings/verifications;
- immutable assignment snapshots;
- realtime event pipeline;
- bounded AI context;
- multi-worker orchestration.

## 21. What v5 removes or replaces

Remove/replace:
- collaborative Workspaces;
- Workspace switching in Conclave AX;
- Workspace memberships/roles;
- Workspace invitations;
- `host_workspace_bindings`;
- Workspace-wide `host.use`;
- Workspace-owned AI Accounts as the default team model;
- shared-Workspace Host access;
- Workspace-scoped Project visibility;
- user-facing Host terminology.

Replace:
- Host -> Workspace;
- Host enrollment -> Workspace enrollment;
- Host session -> Workspace runtime session;
- Host Gateway -> Workspace Gateway;
- Host Worker installation -> Workspace Worker installation;
- Project-under-Workspace -> owner + Project membership;
- Host sharing -> Project Workspace Grant.

## 22. Organizations later

Do not replace Workspace with Organization.

If enterprise needs later require:
- central billing;
- SSO;
- directory provisioning;
- global administrators;
- corporate policy;
- many Projects;
- pooled execution infrastructure;

introduce an explicit Organization above Projects and possibly Workspaces.

Do not overload execution Workspace with organization semantics.

## 23. Migration principle

Conclave is pre-production.

Prefer a clean v5 schema and source migration rather than long-lived compatibility layers.

Compatibility aliases may exist only inside a bounded migration phase and must be removed before the v5 release gate.

## 24. Architecture summary

The v5 mental model should fit in four lines:

> **People collaborate in Projects.**
>
> **Projects explicitly use Workspaces.**
>
> **Workspaces contain Workers and provide execution capacity.**
>
> **AI Accounts remain separately authorized.**
