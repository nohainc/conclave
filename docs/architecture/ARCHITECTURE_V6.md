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
       -> isolated checkout
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

v6 makes mutable state a first-class resource.

Each Workstream has one persistent isolated checkout on one Primary Workspace. Mutating Work Requests are serialized against that checkout.

Different Workstreams may run concurrently on the same Workspace because their checkouts are isolated.

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
- **Primary Workspace** — Workspace that owns the Workstream's persistent mutable checkout.
- **Workstream Checkout** — isolated repository worktree used for stateful execution.
- **Checkpoint** — immutable Git revision recorded after successful stateful work.
- **Execution Lease** — exclusive right to mutate a Workstream Checkout.
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
|    +-- Checkout
|    +-- Checkpoints
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
                    Workstream Checkout
                           |
                           v
                        Workers
                           |
                           v
                       Checkpoint
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
- current checkpoint;
- execution checkout metadata.

Recommended statuses:
- active;
- paused;
- completed;
- archived.

A Workstream is not a generic folder. It is the stable unit that ties together:
- people;
- context;
- execution;
- mutable repository state;
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
- operates on the persistent Workstream Checkout;
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
- owns the persistent Workstream Checkout;
- executes all stateful_workstream steps.

A Workstream may use additional Project Workspaces for stateless_read steps.

Changing Primary Workspace is an explicit migration operation, not a dropdown change during a running Work Request.

## 14. Workstream Checkout

For Git Projects, v6 uses one persistent Git worktree per Workstream.

Recommended managed runtime path:

~~~text
<conclave-data>/
  checkouts/
    <project-id>/
      <workstream-id>/
        <repository-id>/
~~~

Cloud stores only an opaque checkout key and repository/revision metadata. It does not instruct the runtime to use an arbitrary absolute path.

The runtime resolves the checkout key under its managed data directory.

### 14.1 Branch

Each Workstream gets a generated branch, for example:

~~~text
conclave/workstream/<short-workstream-id>
~~~

Names are generated by Conclave, not accepted as arbitrary shell input.

The branch begins at the Project's selected base revision.

### 14.2 Existing runtime primitive

The current GitRepository worktree implementation is retained and extended to support managed named branches and v6 checkout metadata.

## 15. Checkout lifecycle

States:
- provisioning;
- ready;
- leased;
- dirty;
- recovery_required;
- archived;
- error.

Before stateful execution:
1. checkout must exist;
2. current revision must equal expected checkpoint;
3. checkout must be clean;
4. valid Execution Lease must exist.

After successful stateful execution:
1. collect diff;
2. run required verification;
3. create Conclave-managed checkpoint commit if changes exist;
4. record Checkpoint;
5. update Workstream current checkpoint;
6. release lease.

After failed stateful execution:
1. capture bounded diff/diagnostic artifact;
2. reset managed checkout to previous checkpoint;
3. clean generated/untracked state according to policy;
4. release lease;
5. mark Work Request failed.

Because the checkout is Conclave-managed, rollback is safe and does not destroy the user's normal repository checkout.

## 16. Checkpoints

A Checkpoint records:
- Workstream;
- sequence;
- Work Request;
- Run;
- parent Checkpoint;
- repository revision;
- base revision;
- diff artifact;
- verification summary;
- created timestamp.

A successful mutating Work Request advances the Workstream branch to a new Checkpoint.

The Workstream history is therefore:

~~~text
Checkpoint 0
  -> Work Request 1 -> Checkpoint 1
  -> Work Request 2 -> Checkpoint 2
  -> Work Request 3 -> Checkpoint 3
~~~

Users may inspect or revert to previous Checkpoints through an explicit action.

## 17. Mutation concurrency

The invariant:

> One Workstream Checkout has at most one active stateful execution lease.

Different Workstreams may execute stateful work concurrently, even on the same Workspace, because their checkouts are separate.

Read-only Work Requests may run concurrently from a stable Checkpoint.

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
- checkoutId;
- leaseId;
- fencingToken;
- expectedRevision.

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
  -> current Checkpoint/revision
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
  -> active Checkout
  -> exclusive Lease
  -> ready Worker
  -> authorized configured Worker
  -> Assignment bound to Checkout + fencing token
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
- current Checkpoint metadata;
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

A Workstream branch does not automatically mutate the Project's base branch.

Integration actions are explicit:
- publish branch;
- create pull request;
- merge when authorized;
- export patch;
- mark Workstream completed.

For GitHub-backed Projects, Create PR is the preferred integration path.

Project owner policy controls who may integrate.

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

### workstream_checkouts

- id;
- workstream_id;
- project_id;
- workspace_id;
- workspace_project_grant_id;
- opaque source/checkout reference;
- checkout_key;
- branch_name;
- base_revision;
- head_revision;
- status;
- created_at;
- updated_at.

Repository selection is an execution concern. An AI Worker or an authorized Workspace Project Grant may provide the source mapping; the Project and Workstream do not own a repository field. The checkout record may retain an opaque runtime source reference and revision for fencing, recovery, and audit. A repository-free Workstream can remain discussion-only or use stateless work that does not require a checkout.

### workstream_execution_leases

- id;
- workstream_id;
- checkout_id;
- work_request_id;
- run_id;
- fencing_token;
- status;
- acquired_at;
- heartbeat_at;
- expires_at;
- released_at.

### workstream_checkpoints

- id;
- workstream_id;
- checkout_id;
- sequence;
- work_request_id;
- run_id;
- parent_checkpoint_id nullable;
- base_revision;
- revision;
- diff_artifact_id nullable;
- verification_json;
- status;
- created_at.

### Existing execution tables

Add to Goal/Run/Assignment/Artifact/Usage where useful:
- workstream_id;
- work_request_id;
- workflow_version_id;
- checkout_id;
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
- current Checkpoint;
- Primary Workspace;
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
13. Different Workstreams never share the same managed checkout path.
14. Failed stateful Runs cannot leave the next Run starting from unknown dirty state.
15. Successful stateful Runs create an immutable Checkpoint.
16. Workflow version is snapshotted into each Work Request/Run.
17. Account policy cannot grant credentials beyond Account owner's explicit authorization.
18. Workstream context is bounded and explicit.
19. Integration into the Project base branch is explicit.
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
- GitRepository worktree primitive;
- assignment journal/reconciliation;
- Goal/Run/Task/Attempt;
- artifacts/findings/verifications;
- usage/accounting;
- realtime infrastructure.

## 33. What v6 replaces

Replace:
- Chat as the main collaboration/execution object -> Workstream;
- implicit Chat intent execution -> explicit Work Request;
- shared registered repository checkout -> managed Workstream Checkout for stateful work;
- hard-coded workflow progression -> versioned Workflow Definition;
- generic concurrent mutation -> Workstream lease + queue;
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
