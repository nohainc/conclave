# Conclave AX Architecture v6 — Collaborative Workstreams and Isolated Execution

**Status:** Proposed  
**Date:** 2026-09-24  
**Builds on:** Architecture v5 Project-Centric Workspaces

## 1. Executive decision

Architecture v6 keeps the v5 split:

> Project is collaboration. Workspace is execution.

v6 adds a missing unit between them:

> Workstream is the unit of collaborative work and mutable execution inside a Project.

The user-facing model becomes:

~~~text
Project
  -> Workstreams
       -> Discuss
       -> Work
       -> Primary Workspace
       -> Workflow
       -> isolated working directory
~~~

A Workstream is one topic, feature, problem, investigation, or delivery thread that humans and AI work on together.

Each Workstream has two coordinated lanes:

- **Discuss** — human collaboration only. Messages never start AI execution.
- **Work** — explicit AI Work Requests, Runs, results, approvals, changes, checkpoints, and failures.

This replaces the current behavior where a generic Chat message may be interpreted as an execution request.

## 2. Why v6

v5 correctly moved collaboration from shared Workspaces to shared Projects, but it still has two architectural gaps.

### 2.1 Discussion and execution are mixed

The current Chat message path can classify a normal message by intent and start or resume a Goal/Run. This makes a collaborative conversation an implicit execution surface.

For a multi-person Project this creates ambiguity:
- Is a message just discussion?
- Does it spend an AI Account?
- Does it mutate code?
- Which Workspace does it use?
- Which workflow is running?
- Who authorized it?

v6 removes that ambiguity. Discuss never executes. Work always executes explicitly.

### 2.2 Multiple Runs can mutate one checkout

v5 scopes execution to Projects and Workspace Grants, but repository selection is still modeled as a Project-level setting. That cannot represent Projects spanning multiple repositories or Projects with no repository at all, and it encourages the collaboration model to own execution details.

That can cause:
- overlapping edits;
- branch changes during another Run;
- dependency state corruption;
- tests observing half-finished changes;
- false verification;
- unfinished Runs;
- difficult recovery.

v6 makes mutable local state a first-class Workstream resource.

Each Workstream uses one persistent isolated local working directory on its Primary Workspace. Mutating Work Requests are serialized against that directory.

Different Workstreams may run concurrently on the same Workspace because their working directories are isolated. Workers may clone and manage zero, one, or many repositories inside the directory.

## 3. Product vocabulary

### Existing v5 terms retained

- **Project** — shared collaboration and authorization boundary.
- **Workspace** — one user-owned execution environment backed by one machine/runtime.
- **Worker Type** — installable AI/tool capability definition such as Codex or Claude Code.
- **Worker** — configured executable AI/tool identity. A Worker selects one Worker Type, one logical external AI identity, defaults/capabilities, and one or more Workspace bindings.
- **Credential state** — internal authentication metadata/readiness for a Worker on a Workspace. Provider secrets remain local to the Workspace secure store and are not a standalone product resource.
- **Run** — one orchestrated execution.
- **Assignment** — immutable execution snapshot.

### New v6 terms

- **Workstream** — one persistent collaborative unit inside a Project.
- **Discuss** — human discussion lane of a Workstream.
- **Work** — execution lane of a Workstream.
- **Work Request** — explicit human request to run AI work.
- **Workflow Definition** — versioned declarative execution plan.
- **Primary Workspace** — Workspace currently selected for the Workstream's stateful execution.
- **Work Root** — local Workspace root beneath which Workstream working directories are resolved.
- **Workstream Working Directory** — persistent local directory resolved only from immutable Project ID + Workstream ID.
- **Execution Lease** — exclusive right to perform stateful mutation in a Workstream working directory.
- **Execution Sponsor** — optional user/account policy that pays/authenticates Workstream execution.

## 4. Product topology

~~~text
Project
|
+-- Members
|
+-- Workstream: Authentication
|    |
|    +-- Brief
|    +-- Discuss
|    +-- Work
|    +-- Access Policy
|    +-- Default Workflow
|    +-- Primary Workspace
|    +-- Account Policy
|    +-- Working Directory
|
+-- Workstream: Scheduler
     |
     +-- ...
~~~

Execution:

~~~text
Discuss
   |
   | explicit Send to Work / Work request
   v
Work Request
   |
   v
Workflow version snapshot
   |
   +-- stateless/read-only steps -> eligible Project Workspaces
   |
   +-- stateful steps -> Primary Workspace
                           |
                           v
                 Workstream Working Directory
                           |
                           v
                        Workers
~~~

## 5. Workstream model

A Workstream belongs to exactly one Project.

A Workstream contains:
- title;
- brief;
- status;
- creator;
- lead;
- access policy;
- execution policy;
- discussion history;
- Work Request history;
- working-directory execution state.

Recommended statuses:
- active;
- paused;
- completed;
- archived.

A Workstream is not a generic folder. It is the stable unit that ties together:
- people;
- context;
- execution;
- mutable local working state;
- AI history;
- integration status.

## 6. Workstream Brief

Every Workstream has a short persistent Brief.

The Brief should contain:
- purpose;
- current state;
- important decisions;
- constraints;
- expected outcome.

The Brief is part of AI context.

The complete Discuss transcript is not automatically injected into every Run.

Humans may edit the Brief. Conclave may propose updates after a Work Request, but must not silently rewrite it.

## 7. Discuss lane

Discuss is human collaboration.

Properties:
- Project/Workstream authorized humans post messages.
- No intent classifier may start execution from Discuss.
- AI execution controls do not appear in the Discuss composer.
- Work results may appear as compact linked activity cards, not full AI logs.
- Messages may reference Work Requests, Runs, artifacts, commits, findings, and other messages.
- A user can choose **Send to Work** on one or more discussion messages.

Discuss messages are not Goals and do not directly create Runs.

## 8. Work lane

Work is a structured execution timeline displayed with conversational UX.

It contains:
- Work Request cards;
- queued/running state;
- selected Workflow;
- Run progress;
- approvals;
- needs-input events;
- changed files;
- test/evidence summary;
- findings;
- Checkpoint;
- failure/recovery state.

A Work Request is explicit. Pressing **Run** creates it.

The Work lane must not be implemented as a second unrestricted Chat. It is a typed execution surface.

## 9. Work Request state machine

Recommended states:

~~~text
draft
  -> queued
  -> preparing
  -> running
  -> needs_input
  -> completed

queued/running/needs_input
  -> cancelling
  -> cancelled

preparing/running
  -> failed
~~~

A Work Request creates at most one primary Run.

Follow-up work creates a new Work Request linked with parent_work_request_id.

This keeps every iteration independently auditable.

## 10. Workstream access

Project membership remains the maximum authority. Workstream rules may narrow Project permissions but never broaden them.

Effective Workstream capabilities:
- view;
- discuss;
- execute;
- manage.

Default Project mapping:

| Project role | View | Discuss | Execute | Manage |
| --- | --- | --- | --- | --- |
| owner | yes | yes | yes | yes |
| collaborator | yes | yes | yes | no |
| viewer | yes | no | no | no |

Workstream policy may use:
- visibility: all_project_members or restricted;
- discuss: collaborators, selected_members, lead_only;
- execute: collaborators, selected_members, lead_only.

Project owner always retains manage authority.

A Project viewer can never become an executor through a Workstream override.

## 11. Workstream Lead

Each Workstream has one Lead.

The Lead must be the Project owner or a Project collaborator.

The Lead may:
- edit the Brief;
- manage Workstream-specific access within Project limits;
- select default Workflow;
- select Primary Workspace from valid Project Workspace Grants;
- choose execution Account policy;
- archive/complete the Workstream.

Project owner may override all Workstream settings.

## 12. Workflow definitions

v6 replaces hard-coded orchestration shape with versioned Workflow Definitions.

A Workflow Definition is provider-independent.

A Workflow version contains ordered/dependency-aware steps. Each step declares:
- id;
- name;
- role;
- required capabilities;
- execution class;
- dependencies;
- independence requirement;
- optional approval boundary;
- timeout;
- result contract.

### 12.1 Execution classes

Use two primary execution classes.

**stateless_read**
- no persistent mutation;
- runs against an immutable checkpoint/revision/context snapshot;
- may execute on any eligible Project Workspace;
- may run in parallel.

Examples:
- research;
- architecture analysis;
- independent review;
- comparison.

**stateful_workstream**
- operates in the persistent Workstream Working Directory;
- must execute on the Primary Workspace;
- participates in the Workstream's exclusive Execution Lease.

Examples:
- implementation;
- refactor;
- dependency update;
- tests against modified tree;
- review of uncommitted/just-modified state;
- checkpoint creation.

If a Workflow contains one or more stateful_workstream steps, the stateful segment is serialized.

### 12.2 Built-in Workflow presets

Initial presets:
1. Research
2. Review
3. Implementation
4. Implementation + Test + Review
5. Research + Implementation
6. Full Cycle: Research -> Plan -> Implement -> Test -> Review

Workstream stores a default Workflow version. Each Work Request may override it.

Workers are not assigned directly to Workstreams. Workflow steps declare roles/capabilities and the scheduler resolves Workers.

## 13. Primary Workspace

A Workstream with mutable work has one Primary Workspace.

The Primary Workspace:
- must have an active WorkspaceProjectGrant for the Project;
- must contain or be able to install required Workers;
- resolves the Workstream's persistent local Working Directory;
- executes all stateful_workstream steps.

A Workstream may use additional Project Workspaces for stateless_read steps.

Changing Primary Workspace is not allowed during an active stateful Work Request. Local files are not transferred automatically; the destination Workspace resolves the same Project-ID/Workstream-ID relative path under its own Work Root and may need to reconstruct repository state through Git or explicit user instructions.

## 14. Workstream Working Directory

Conclave does not require a Source/repository registry for the initial v6 execution model.

Each Workspace runtime has one local Work Root. For a Workstream, the runtime resolves:

~~~text
<work-root>/
  <project-id>/
    <workstream-id>/
~~~

Only immutable IDs participate in path identity.

Do not include:
- Project name;
- Workstream name;
- user email/name;
- Workspace ID;
- Worker name;
- repository name.

Project and Workstream renames therefore have zero effect on active or future execution paths.

The Workstream directory is created lazily when executable Work first reaches that Workspace. It persists across Work Requests and Workspace re-enrollment on the same local installation when the Work Root is preserved.

The runtime stores a small identity marker such as `.conclave-workstream.json` containing stable non-secret metadata (schema version, Project ID, Workstream ID, creation timestamp). Existing directories are reused only after marker validation.

Cloud never supplies an arbitrary absolute working directory. Assignments carry Project/Workstream identity; the Workspace runtime resolves the local path and launches each Worker with the Workstream directory as its CWD.

### 14.1 Repository behavior

Repositories inside the directory are Worker-managed.

A Worker may:
- clone public/private repositories;
- use multiple repositories;
- create branches;
- fetch/pull;
- merge/rebase;
- commit/push;
- generate non-repository files.

Conclave does not initially provision repositories, create branches, or guarantee automatic Git rollback/checkpoint commits.

Two Workstreams may independently clone the same repository into their separate directories and work in parallel. Git is the synchronization/integration mechanism between them.

### 14.2 Re-enrollment and machine changes

Workspace ID is runtime enrollment identity, not Workstream storage identity.

If a Workspace is deleted/revoked and the same local installation is paired again with a new Workspace ID, the runtime resolves the same `<project-id>/<workstream-id>` path and reuses it after marker validation.

If execution moves to another physical machine, the same relative path may be created under that machine's Work Root, but local files are not automatically transferred.

## 15. Working-directory lifecycle

States can remain minimal:
- absent;
- ready;
- conflict;
- unavailable.

Defaults:
- active Workstream: retain;
- completed: retain;
- archived: retain;
- Cloud-deleted: retain locally until explicit cleanup.

Conclave should fail closed on marker/path conflicts rather than overwrite unknown local data.

## 16. Git state and recovery

Conclave's initial filesystem guarantee is Workstream isolation and serialized stateful mutation, not Git checkpoint management.

Workers/users are responsible for Git-level recovery and synchronization.

A future observability layer may discover repositories under the Workstream directory and report:
- remote;
- branch;
- HEAD;
- dirty state;

without making repository registration a prerequisite for execution.

## 17. Mutation concurrency

The invariant:

> One Workstream Working Directory has at most one active stateful execution lease.

Different Workstreams may execute stateful work concurrently, even on the same Workspace, because their directories are separate.

Read-only/stateless work may run concurrently when its workflow and permissions allow it.

## 18. Workstream Execution Coordinator

Use one Durable Object per Workstream as the low-latency coordinator for:
- write queue;
- active lease;
- lease heartbeat;
- fencing token;
- cancellation ordering;
- stateful Work Request wake-up.

D1 remains the persistent source of truth.

The coordinator must reconstruct state from D1 after restart.

Each new exclusive lease receives a monotonically increasing fencing token.

Assignments for stateful steps carry:
- workstreamId;
- workRequestId;
- leaseId;
- fencingToken.

The Workspace runtime rejects stale or mismatched fencing tokens.

A local checkout lock provides a second line of defense.

## 19. Queue behavior

Initial behavior:
- stateful Work Requests are FIFO per Workstream;
- one stateful Work Request active at a time;
- users may cancel a queued item;
- no arbitrary priority/reordering in the first release;
- stateless read-only Work Requests do not need the write queue.

This intentionally favors determinism over maximum concurrency.

## 20. Scheduler v6

Selection begins from Work Request + Workflow step.

For stateless_read:

~~~text
Work Request
  -> Project
  -> Workstream access
  -> Workflow step
  -> eligible Project Workspace Grants
  -> ready Workers
  -> authorized configured Workers
  -> package/credential readiness
  -> capacity / budget / independence
  -> Assignment
~~~

For stateful_workstream:

~~~text
Work Request
  -> Workstream
  -> Primary Workspace Grant
  -> ready Workstream Working Directory
  -> exclusive Lease
  -> ready Worker
  -> authorized configured Worker
  -> Assignment bound to Workstream directory identity + fencing token
~~~

The scheduler may never route a stateful step to an auxiliary Workspace.

## 21. AI Account policy

Workstream execution Worker policy is separate from Workspace access.

Supported policy shapes may include:
- requester-owned Workers;
- sponsor-authorized Workers;
- Project-shared Workers;
- explicit Worker IDs;
- auto-authorized Workers.

Recommended default: requester-owned or otherwise explicitly authorized Workers.

The configured Worker is the user-facing resource. Credential/account authorization remains an internal security check beneath the Worker and may only narrow eligibility.

### Sponsor mode

A Workstream may have an Execution Sponsor, typically the Lead or Project owner.

Sponsor mode means collaborators may use selected sponsor Accounts only when:
- Account owner explicitly granted the Account to the Project;
- Workstream policy allows the Account;
- provider sharing policy permits it;
- budget policy allows it.

Workstream settings can narrow Account use but never create Account authorization by themselves.

Usage records preserve both requester and Account owner.

## 22. Context assembly

A Work Request receives bounded context:

- Project instructions;
- Workstream Brief;
- relevant Workstream/local-state metadata when available;
- current request;
- explicitly referenced Discuss messages;
- explicitly referenced artifacts/findings;
- Workflow-specific context.

Do not inject the complete Discuss transcript by default.

This keeps execution context deterministic and prevents long-running Workstreams from accumulating unbounded prompt history.

## 23. Send to Work

Discuss supports an explicit **Send to Work** action.

It:
1. opens the Work composer;
2. references selected discussion messages;
3. copies or summarizes selected text into a draft request;
4. lets the user select Workflow;
5. requires explicit Run action.

No Discuss message executes automatically.

## 24. Work completion in Discuss

When a Work Request reaches a meaningful terminal state, Discuss may show a compact activity card:

~~~text
Conclave
Work Request #42 completed
7 files changed · tests passed · 1 review finding
[Open Work]
~~~

Full logs, steps, model output, diffs, evidence, and approvals remain in Work.

## 25. Needs-input behavior

Before the stateful segment, Workflow may wait for human approval without taking the write lease.

After a stateful lease is acquired, correctness takes priority over throughput.

Initial v6 rule:
- a stateful Run that enters needs_input retains the exclusive lease;
- later Work Requests stay queued;
- user can respond, cancel, or choose an explicit recovery action.

A future optimization may snapshot-and-release paused state, but v6 should not introduce merge/rebase complexity prematurely.

## 26. Integration back to Project

Conclave does not initially own repository branches or base-branch integration.

Workers/users use normal repository workflows inside the Workstream directory:
- branch;
- commit;
- fetch/pull;
- merge/rebase;
- push;
- pull request.

GitHub integration may later provide convenience actions, but repository registration is not required for Workstream execution.

## 27. Data model

Recommended v6 tables.

### workstreams

Fields:
- id;
- project_id;
- title;
- brief;
- status;
- created_by_user_id;
- lead_user_id;
- visibility;
- current_checkpoint_id;
- created_at;
- updated_at.

### workstream_memberships

Optional narrowing/restricted membership:
- workstream_id;
- user_id;
- role: lead, contributor, viewer;
- discuss_allowed;
- execute_allowed.

Membership never broadens beyond Project role.

### discussion_messages

- id;
- workstream_id;
- sender_user_id;
- content;
- references_json;
- created_at;
- edited_at;
- deleted_at.

### workflow_definitions

- id;
- scope: system or project;
- project_id nullable;
- name;
- description;
- status.

### workflow_versions

- id;
- workflow_definition_id;
- version;
- steps_json;
- created_at.

Run snapshots the exact Workflow version.

### workstream_execution_policies

- workstream_id;
- primary_workspace_grant_id;
- default_workflow_version_id;
- account_policy;
- sponsor_user_id nullable;
- allowed_account_ids_json;
- created_at;
- updated_at.

### work_requests

- id;
- workstream_id;
- created_by_user_id;
- parent_work_request_id nullable;
- prompt;
- workflow_version_id;
- workflow_snapshot_json;
- referenced_discussion_ids_json;
- status;
- run_id nullable;
- base_checkpoint_id nullable;
- result_checkpoint_id nullable;
- queued_at;
- started_at;
- finished_at.

### local Workstream working-directory state

The canonical directory path is runtime-derived and does not require a Cloud checkout table:

~~~text
<work-root>/<project-id>/<workstream-id>
~~~

Cloud may keep only coarse runtime state when useful:
- absent;
- ready;
- conflict;
- unavailable.

Absolute local paths are not required in Cloud.

### Existing execution tables

Add to Goal/Run/Assignment/Artifact/Usage where useful:
- workstream_id;
- work_request_id;
- workflow_version_id;
- execution_lease_id;
- fencing_token;
- expected_revision.

## 28. API shape

Project:
- list/create Workstreams.

Workstream:
- read/update/archive;
- list/update access;
- Discuss messages;
- Work Requests;
- Brief;
- execution settings;
- Checkpoints;
- integration actions.

Recommended routes:

~~~text
GET/POST   /api/projects/:projectId/workstreams
GET/PATCH  /api/workstreams/:workstreamId

GET/POST   /api/workstreams/:workstreamId/discuss/messages
POST       /api/workstreams/:workstreamId/work-requests
GET        /api/workstreams/:workstreamId/work-requests
POST       /api/work-requests/:id/cancel

GET/PATCH  /api/workstreams/:workstreamId/execution
GET        /api/workstreams/:workstreamId/checkpoints
POST       /api/workstreams/:workstreamId/checkouts/provision
~~~

Discuss message creation has no orchestration side effect.

## 29. Realtime

Add Workstream scope.

Events:
- workstream.updated;
- discussion.message.created/edited;
- work_request.queued/started/completed/failed/cancelled/needs_input;
- checkout.provisioning/ready/dirty/recovered;
- lease.acquired/released/expired;
- checkpoint.created/reverted;
- integration.updated.

Subscriptions:
- Project;
- Workstream;
- Run;
- owned Workspace.

The UI should not need full Project snapshot reloads for every Work event.

## 30. UI/UX

### Project page

Replace Chats as the primary collaboration list with Workstreams.

Recommended Project navigation:
- Overview;
- Workstreams;
- Runs;
- Artifacts;
- Members;
- Execution;
- Settings.

### Workstream page

Header:
- title;
- status;
- Lead;
- Primary Workspace;
- Working Directory readiness;
- active/queued Work state.

Primary tabs:
- Discuss;
- Work.

Optional secondary surfaces:
- Changes;
- Settings.

### Discuss composer

Human text only.

No Worker/Model/Workspace/Account selector.

### Work composer

Contains:
- request;
- Workflow selector;
- optional references;
- concise execution summary.

Advanced:
- Workspace override only when Workflow step is stateless or policy permits;
- Worker override within authorization;
- model/quality controls.

Primary button is **Run**, not Send.

## 31. Security invariants

1. Discuss never starts AI execution.
2. Work Request execution is always explicit and attributable to a user.
3. Project authorization is the outer collaboration boundary.
4. Workstream access may narrow but never broaden Project role.
5. Workspace access still requires v5 Workspace Grants.
6. Configured Worker authorization remains independent from Workspace access; underlying credential authorization remains an internal security boundary.
7. Stateful execution uses only the Workstream Primary Workspace.
8. Stateful execution uses only the managed Workstream Checkout.
9. At most one active stateful lease exists per Checkout.
10. Stateful Assignments carry a fencing token and expected revision.
11. Runtime rejects stale lease tokens and revision mismatches.
12. Worker cannot choose an arbitrary working directory.
13. Different Workstreams never share the same working-directory path.
14. Project/Workstream renames never alter working-directory identity.
15. Workspace re-enrollment does not alter working-directory identity.
16. Workflow version is snapshotted into each Work Request/Run.
17. Configured Worker policy cannot grant credentials beyond existing authorization.
18. Workstream context is bounded and explicit.
19. Repository operations remain Worker/user responsibilities unless an explicit future integration is invoked.
20. Legacy Chat intent inference is not an execution authority.

## 32. What v6 keeps from v5

Keep:
- Project membership and invitations;
- user-owned Workspaces;
- WorkspaceProjectGrant;
- Project Account grants;
- v5 scheduler eligibility concepts, adapted to configured Workers;
- Workspace Gateway;
- Worker Type package desired state;
- Worker package signing;
- runtime permission enforcement;
- SafeWorkspace;
- Git/GitHub tooling as Worker-accessible local capabilities;
- assignment journal/reconciliation;
- Goal/Run/Task/Attempt;
- artifacts/findings/verifications;
- usage/accounting;
- realtime infrastructure.

## 33. What v6 replaces

Replace:
- Chat as the main collaboration/execution object -> Workstream;
- implicit Chat intent execution -> explicit Work Request;
- shared registered repository checkout -> ID-based isolated Workstream Working Directory;
- hard-coded workflow progression -> versioned Workflow Definition;
- generic concurrent mutation -> Workstream directory lease + queue;
- per-message execution controls in normal discussion -> Work lane execution composer.

## 34. Migration stance

Conclave is pre-production.

Prefer:
- clean v6 schema baseline;
- reset development D1;
- intentional fixture conversion;
- no long-lived v5/v6 compatibility views.

If preserving development data is useful, provide a one-time converter:
- Chat -> Workstream;
- existing Chat messages -> Discuss;
- existing linked Runs -> historical Work activity.

The converter is tooling, not production compatibility architecture.

## 35. Architecture summary

The v6 mental model should be explainable in six lines:

> Projects contain Workstreams.  
> People talk in Discuss.  
> AI work starts only from Work.  
> A Workstream has one Primary Workspace for mutable state.  
> Each Workstream has its own isolated checkout.  
> Mutating work is serialized; read-only work may run in parallel.
