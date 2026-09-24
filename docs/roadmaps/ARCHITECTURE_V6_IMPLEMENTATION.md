# Architecture v6 Implementation Roadmap — Collaborative Workstreams

**Status:** Proposed  
**Architecture:** [ARCHITECTURE_V6.md](../architecture/ARCHITECTURE_V6.md)  
**Source audit:** [V6_SOURCE_AUDIT.md](../architecture/V6_SOURCE_AUDIT.md)  
**Date:** 2026-09-24

## Global rules

For every phase:
1. read Architecture v6 and v5 guardrails;
2. inspect current source before changes;
3. keep main green;
4. no new v4 compatibility code;
5. one architectural concern per PR;
6. tests land with the behavior;
7. remove replaced paths once the new path is proven;
8. Discuss may never execute;
9. stateful execution may never use an unleased shared checkout;
10. AI Account and Workspace Grants remain independent.

---

## V6-0 — Converge the implemented v5 baseline

### Goal
Remove remaining v4/v5 dual behavior before Workstreams.

### Remove from App
- active Workspace selection;
- Workspace switcher;
- collaborative Workspace create/settings/invitations;
- active Workspace header/state;
- `x-conclave-workspace-id` behavior.

### Remove from security
- WorkspaceRole active authorization;
- WORKSPACE_ROLE_PERMISSIONS active path;
- old Workspace resolver;
- Host Workspace binding helpers;
- old credential authorization path.

### Remove from Cloud
- collaborative Workspace CRUD/members/invitations;
- Host-to-Workspace binding;
- old Workspace-scoped Chat/Goal/Run SQL;
- legacy assignment fallback;
- old Host enrollment APIs replaced by execution Workspace enrollment.

### Canonicalize Core
- promote v5 entities;
- isolate/delete legacy Workspace/Host/Agent types.

### Tests
- architecture search gate;
- App no Workspace switch test;
- Project direct-link authorization;
- owned Workspace resource listing;
- assignment always takes v5 path.

### Exit
One active architecture remains before v6 features.

---

## V6-1 — Define Workstream domain

### Add
- Workstream;
- WorkstreamStatus;
- WorkstreamAccessPolicy;
- WorkstreamLead;
- DiscussionMessage;
- WorkRequest;
- WorkRequestStatus;
- WorkflowDefinition;
- WorkflowVersion;
- WorkflowStep;
- WorkstreamExecutionPolicy;
- WorkstreamCheckout;
- WorkstreamCheckpoint;
- WorkstreamExecutionLease.

### Invariants
- Workstream belongs to Project;
- Lead must be owner/collaborator;
- Workstream permission can only narrow Project permission;
- stateful Work Request requires Primary Workspace/Checkout;
- one active stateful lease per Checkout;
- Checkpoint sequence linear per Workstream checkout.

### Tests
Domain invariants and serialization.

### Exit
Core fully describes v6 without UI/storage assumptions.

---

## V6-2 — Define Workflow contract

### Goal
Replace hardcoded orchestration shape with versioned workflows.

### Schema
WorkflowStep:
- id/name;
- role;
- requiredCapabilities;
- executionClass: stateless_read | stateful_workstream;
- dependsOn;
- independentFrom;
- approval;
- timeout;
- outputContract.

### Built-ins
- Research;
- Review;
- Implementation;
- Implementation + Test + Review;
- Research + Implementation;
- Full Cycle.

### Versioning
- immutable versions;
- Work Request snapshots exact version;
- editing creates next version.

### Tests
- DAG validation;
- dependency cycle;
- invalid stateful ordering;
- snapshot immutability.

### Exit
Workflow runner can execute data, not hardcoded stage names.

---

## V6-3 — Clean v6 schema

### Create/replace
- workstreams;
- optional workstream_memberships;
- discussion_messages;
- workflow_definitions;
- workflow_versions;
- workstream_execution_policies;
- work_requests;
- workstream_checkouts;
- workstream_execution_leases;
- workstream_checkpoints.

### Add correlation
To Runs/Assignments/Artifacts/Usage:
- workstream_id;
- work_request_id;
- workflow_version_id;
- checkout_id;
- execution_lease_id where stateful.

### Strategy
Pre-production:
- create clean `migrations-v6/0001_conclave_v6.sql`;
- reset dev D1;
- no compatibility views.

### Tests
- SQLite clean apply;
- FK/unique constraints;
- one active checkout;
- lease uniqueness;
- checkpoint parent constraints.

### Exit
Persistence matches v6 directly.

---

## V6-4 — Split Discuss from Work

### Discuss API
- create/read/edit discussion messages;
- references only;
- no intent execution.

### Remove
- Chat intent as orchestration authority;
- `startChatExecution` from generic message path;
- automatic resume from discussion.

### Work API
- create Work Request;
- requires execute authorization;
- records requester;
- validates Workflow;
- explicit Run.

### Tests
- Discuss cannot create Goal/Run under any content;
- Work request does;
- viewer denied;
- collaborator allowed;
- audit attribution.

### Exit
Human speech cannot accidentally spend/mutate resources.

---

## V6-5 — Workstream authorization

### Implement
- canViewWorkstream;
- canDiscussWorkstream;
- canExecuteWorkstream;
- canManageWorkstream.

### Policy
Project role outer bound.
Workstream may restrict:
- visibility;
- discuss;
- execute.

### Defaults
Owner: all.
Collaborator: view/discuss/execute.
Viewer: view.

### Tests
- selected-member restrictions;
- viewer never elevated;
- removed Project member loses Workstream access;
- Lead permissions;
- Project owner override.

### Exit
Workstream access is simple and auditable.

---

## V6-6 — Workstream Project UX shell

### Project
- replace Chats tab/list with Workstreams;
- create/archive Workstream;
- show Lead/status/active work.

### Workstream page
- Discuss tab;
- Work tab;
- title/status;
- Brief;
- Primary Workspace summary;
- current Checkpoint;
- queue/running status.

### Do not add execution yet
Use fixtures/API skeleton if needed.

### Tests
- navigation/deep links;
- responsive;
- role-specific controls;
- accessibility.

### Exit
Users understand Workstream before execution complexity lands.

---

## V6-7 — Runtime managed checkout manager

### Goal
Turn existing Git worktree primitive into production Workstream state.

### Add runtime service
`WorkstreamCheckoutManager`.

Responsibilities:
- managed root;
- provision checkout;
- generated branch;
- resolve checkout ID;
- verify branch/revision;
- local lock;
- status/diff;
- reset/recover;
- checkpoint commit;
- archive/remove.

### Security
- Cloud sends opaque checkout ID;
- runtime generates/resolves path;
- no arbitrary absolute path from assignment;
- reuse SafeWorkspace and GitRepository.

### Tests
- idempotent provisioning;
- two Workstreams isolated;
- path traversal;
- symlink;
- branch validation;
- dirty recovery;
- crash/reopen.

### Exit
A Workstream has a safe persistent checkout.

---

## V6-8 — Checkout provisioning control plane

### Cloud
When Primary Workspace selected:
- validate active WorkspaceProjectGrant;
- create checkout record;
- send provision command;
- record ready/head revision.

### Protocol
Add:
- checkout.provision;
- checkout.status;
- checkout.recover;
- checkout.archive.

### Realtime
Expose provisioning state.

### Tests
- Workspace offline;
- repository missing;
- wrong base revision;
- retry/idempotency;
- grant revoked.

### Exit
UI can reliably create the Workstream checkout.

---

## V6-9 — Workstream execution coordinator

### Durable Object per Workstream

Responsibilities:
- FIFO stateful queue;
- active lease;
- fencing token;
- heartbeat/expiry;
- cancellation;
- reconciliation.

### D1
Persistent lease/queue states remain authoritative.

### Behavior
- one stateful Work Request active;
- stateless requests bypass write queue;
- queued cancellation;
- no manual priority initially.

### Tests
- simultaneous enqueue;
- DO restart;
- lease expiry;
- stale worker;
- cancellation;
- duplicate request/idempotency.

### Exit
Stateful concurrency is deterministic.

---

## V6-10 — Runtime lease fencing

### Assignment snapshot adds
- workstreamId;
- workRequestId;
- checkoutId;
- leaseId;
- fencingToken;
- expectedRevision;
- executionClass.

### Runtime
Before stateful Worker launch:
- checkout exists;
- lease matches;
- token >= local last-seen fencing token;
- expected revision matches;
- checkout clean.

Reject otherwise.

### Local lock
OS/file lock per checkout.

### Tests
- stale token;
- duplicate assignment;
- revision mismatch;
- second process lock;
- reconnect replay.

### Exit
Cloud bugs/retries cannot produce concurrent mutation.

---

## V6-11 — Scheduler v6

### Extend v5 scheduler

For stateless_read:
- retain Auto Workspace selection;
- bind to Checkpoint revision;
- no persistent mutation.

For stateful_workstream:
- force Primary Workspace;
- force Primary Workspace Grant;
- require checkout + lease;
- select Worker/Account only inside that boundary.

### Remove
- arbitrary Workspace override for stateful steps.

### Tests
- auxiliary research Workspace;
- Primary Workspace offline;
- Account unavailable on Primary;
- correct Worker selection;
- workspace capacity + Workstream lease interaction.

### Exit
Scheduler respects mutable-state topology.

---

## V6-12 — Workflow runner

### Goal
Drive Runs from WorkflowVersion.

### Runner
- create Tasks from steps;
- preserve dependencies;
- route stateless/stateful;
- approvals;
- needs-input;
- result contracts.

### Cloudflare Workflow
Keep durable orchestration, but stop hardcoding research/planning/implementation/verification as the only path.

### Tests
- all built-ins;
- failure propagation;
- approval;
- retry;
- cancellation;
- multi-worker independence.

### Exit
Workflows are product data with immutable versions.

---

## V6-13 — Checkpoint and rollback lifecycle

### On success
- verify dirty tree;
- create managed commit;
- create diff artifact;
- record Checkpoint;
- update Workstream current checkpoint;
- release lease.

### On failure/cancel
- capture bounded diagnostics/diff;
- reset checkout to base checkpoint;
- clean controlled untracked files;
- mark recovery status if rollback fails;
- release or quarantine lease.

### No-change success
Record Run result without unnecessary commit; checkpoint may remain unchanged.

### Tests
- successful commit;
- failed rollback;
- untracked files;
- dependency changes;
- no-change;
- cancellation.

### Exit
Next Work Request always starts from known state.

---

## V6-14 — Work composer and Work timeline

### Work composer
- request text;
- Workflow selector;
- references;
- Run button.

### Advanced
- Account override;
- model/quality;
- only valid Workspace controls;
- no fixed Worker default at Workstream level.

### Timeline cards
- queued;
- preparing;
- running;
- needs input;
- completed;
- failed;
- checkpoint;
- changes/tests/findings.

### Tests
- explicit Run required;
- queue visualization;
- cancellation;
- needs-input response;
- role gating.

### Exit
AI execution is understandable without reading raw orchestration data.

---

## V6-15 — Discuss UX and Send to Work

### Discuss
- human messages;
- replies/references;
- editing policy;
- linked activity cards.

### Send to Work
- one/multiple messages;
- opens Work draft;
- references source messages;
- does not run automatically.

### Completion notification
Compact Discuss event linking to Work result.

### Tests
- no execution controls;
- Send to Work draft only;
- result card;
- realtime multi-user updates.

### Exit
Human collaboration and AI execution feel connected but distinct.

---

## V6-16 — Workstream Brief and context builder

### Brief
Editable:
- purpose;
- state;
- constraints;
- expected outcome.

### Context assembly
Include:
- Project instructions;
- Brief;
- current Checkpoint;
- Work Request;
- explicit Discuss references;
- explicit artifacts;
- Workflow requirements.

### Exclude
- full discussion transcript by default;
- unrelated Work Requests;
- provider history unless session policy says so.

### Tests
- bounded context;
- stable ordering;
- reference authorization;
- removed message/reference behavior.

### Exit
AI context remains deterministic over long-lived team work.

---

## V6-17 — Account policy / sponsor mode

### Workstream policy
Modes:
- requester;
- sponsor;
- project_shared;
- explicit_accounts;
- auto_authorized.

### Sponsor
- sponsor must authorize Accounts via existing ProjectAccountGrant;
- Workstream policy only narrows;
- usage stores requester and Account owner.

### Budgets
Optional Workstream budget and per-request estimate.

### Tests
- requester own account;
- sponsor account;
- revoked grant;
- provider private-only;
- budget exceeded;
- Account not installed on Primary Workspace.

### Exit
Team execution cost/identity is explicit.

---

## V6-18 — Multi-Workspace stateless fan-out

### Goal
Allow research/review to use auxiliary Workspaces safely.

### Context
Use immutable:
- Checkpoint SHA;
- R2/context artifacts;
- repository snapshot mechanism supported by Workspace.

Do not point auxiliary Workers at Primary mutable checkout.

### Tests
- parallel research;
- independent provider requirement;
- stale snapshot;
- Primary mutates while research runs;
- synthesis uses correct revision metadata.

### Exit
Conclave gains parallelism without shared mutable filesystem risk.

---

## V6-19 — Integration workflow

### Actions
- Publish branch;
- Create PR;
- Merge;
- Export patch;
- Mark completed.

### GitHub
Prefer PR for connected GitHub repositories.

### Permissions
Project owner policy determines who can integrate.

### Record
Integration state belongs to Workstream.

### Tests
- PR creation metadata;
- branch already published;
- base moved;
- merge conflict;
- unauthorized integration.

### Exit
Workstream output has a controlled route back to Project base.

---

## V6-20 — Realtime and notifications

### Scopes
- Project;
- Workstream;
- Run;
- owned Workspace.

### Events
Discussion, Work Request, checkout, lease, checkpoint, integration.

### Notification policy
Notify only actionable/meaningful states:
- needs input;
- Work completed/failed;
- grant/account problem;
- recovery required.

### Tests
- two users same Workstream;
- two tabs;
- reconnect gaps;
- membership removal;
- queue updates.

### Exit
No polling/full snapshot reload needed for active team work.

---

## V6-21 — Usage, audit and observability

### Usage dimensions
- Project;
- Workstream;
- Work Request;
- requester;
- Workspace;
- Worker;
- Account;
- Account owner;
- Workflow;
- tokens/cost/duration.

### Audit
- discussion moderation if needed;
- Work Request creation;
- workflow selection;
- Account selection;
- checkout provision/recovery;
- lease;
- checkpoint;
- integration.

### Metrics
- queue wait;
- stateful duration;
- checkout recovery rate;
- failed rollback;
- Workspace utilization.

### Exit
Failures and cost are explainable per Workstream iteration.

---

## V6-22 — Migration from Chat to Workstream

### Development strategy
Prefer clean v6 reset if acceptable.

If preserving fixtures:
- create Workstream per Chat;
- migrate human conversational content to Discuss;
- connect historical Runs into Work activity;
- preserve IDs through mapping table/tool.

### Remove
- generic Chat intent execution;
- old Chats primary navigation;
- execution controls from normal chat composer.

### Exit
No active product feature depends on Chat as an execution authority.

---

## V6-23 — Architecture cleanup gate

Search active source for forbidden remnants:
- Workspace switching tenant UX;
- old WorkspaceRole active authorization;
- `host_workspace_bindings`;
- v4 configured Worker fallback;
- normal Chat -> automatic Goal/Run;
- mutable assignment using registered base repository path directly;
- user-supplied arbitrary worktree path;
- provider-specific Workflow branching.

Historical docs/tests may retain explicit historical references.

### Exit
One coherent v6 architecture.

---

## V6-24 — Clean-room solo acceptance

1. sign in;
2. add execution Workspace;
3. connect Worker/Account;
4. create Project;
5. grant Workspace;
6. create Workstream;
7. provision checkout;
8. Discuss;
9. create explicit Work Request;
10. workflow runs;
11. checkpoint created;
12. second iteration starts from checkpoint;
13. create PR.

### Exit
Complete solo flow works from empty DB.

---

## V6-25 — Team concurrency acceptance

Scenario:
- Project owner + 3 collaborators;
- Workstream A and B on same Mac Workspace;
- Workstream C on another Workspace.

Verify:
- all can Discuss;
- configured members can execute;
- two stateful Requests in same Workstream serialize;
- different Workstreams run concurrently;
- checkout paths never overlap;
- failed Workstream A Run does not affect B;
- viewer cannot execute;
- Account sponsor attribution correct;
- removal from Project immediately blocks new work.

### Exit
The original team problem is proven solved.

---

## V6-26 — Security and recovery acceptance

Test:
- path traversal;
- symlink escape;
- stale fencing;
- forged checkout ID;
- expected revision mismatch;
- duplicate dispatch;
- Workspace crash during mutation;
- Cloud/DO restart;
- failed rollback/quarantine;
- Account grant revocation;
- Workspace Grant revocation;
- malicious Worker permission request;
- secret redaction.

### Exit
No known path lets shared Project execution escape its Workstream/Workspace boundary.

---

## V6-27 — UI/UX acceptance

A new user should understand:
- Project = team;
- Workstream = one thing the team is working on;
- Discuss = talk;
- Work = AI execution;
- Workspace = computer/runtime;
- Workflow = how AI work is performed.

Avoid exposing implementation terms:
- lease;
- fencing token;
- Durable Object;
- checkout key.

Show them only in diagnostics.

### Exit
Normal team use requires no architecture knowledge.

---

## V6-28 — Release gate

Required:
- TypeScript/Dart/Flutter green;
- clean v6 schema apply;
- protocol generation green;
- macOS runtime acceptance;
- Windows/Linux compile;
- solo acceptance;
- team concurrency acceptance;
- recovery/security matrix;
- architecture search gate;
- docs consistency;
- production Cloudflare preflight.

Final product test:

> Four people can discuss one feature, explicitly ask AI to work on it, iterate safely, and run other features in parallel without corrupting each other's environment.
