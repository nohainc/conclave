# Conclave AX Workspaces UX and Data Contract

**Status:** Phase 1 contract; implementation changes are pending later phases.

**Applies to:** Conclave AX and its Cloud read models.

**Architecture:** v7, Workspace-owned Workers.

## Product contract

The top-level AX execution-capacity page is **Workspaces**.

```text
Workspaces
└── Workspace
    ├── Workers
    ├── Project access
    ├── Activity summary
    └── Machine details and settings
```

- A Workspace is the Cloud resource representing one enrolled machine runtime.
- A Workspace contains its synchronized Workers. A Worker belongs to exactly
  one owning Workspace.
- Workers are visible and schedulable in AX, but have no independent
  top-level page or global inventory destination.
- Workers are created, authenticated, permissioned, and removed locally in
  Conclave Workspace. AX never configures their local execution environment.
- Project access is managed as a Workspace Grant in AX. A Workspace can be
  granted to multiple Projects; it is not paired separately for each Project.
- Stateful Workstreams remain restricted to their Primary Workspace. Stateless
  work may use another Workspace only when its grant and execution policy allow
  it.

This contract defines the target UX and frontend read model. It does not claim
that the current screens, route parser, or app models already conform. Phase 1
does not restructure application code or delete compatibility paths.

## Canonical Workspace overview model

AX renders each card from a `StudioWorkspaceOverview` read model. It may be
assembled from multiple Cloud APIs or returned by one aggregate endpoint; the
read model is the contract, not a requirement for one physical endpoint.

```text
StudioWorkspaceOverview {
  workspace: WorkspaceSummary
  runtime: WorkspaceRuntimeSummary
  workers: List<WorkspaceWorkerSummary>
  projectGrants: List<WorkspaceProjectGrantSummary>
  activity: WorkspaceActivitySummary
}
```

### `WorkspaceSummary`

```text
id
name
lifecycleState       // active | revoked
accessRole           // current user's Cloud role
createdAt
```

Cloud owns the Workspace record, name, lifecycle, and caller's access role.
Opaque IDs and timestamps remain available to routing, diagnostics, and audit;
the normal card leads with the name.

### `WorkspaceRuntimeSummary`

```text
connectionState      // connected | offline | not_connected | unknown
hostname?
operatingSystem?
architecture?
appVersion?
lastSeenAt?
runtimeFactsUpdatedAt?
```

Runtime identity, live connection state, and safe reported machine facts are
Cloud-owned observations of the paired desktop. A missing fact is unknown; the
UI must not fabricate a platform, version, worker count, or activity value.
Internal runtime identity and raw capabilities belong in diagnostics, not the
ordinary Workspace card.

### `WorkspaceWorkerSummary`

```text
id
name
workerTypeId
defaultModel?
localReadiness       // ready | needs_attention | disabled | removed
attentionReasonCode? // safe, actionable code; no provider output or secret
schedulingState      // enabled | disabled | draining
credentialState      // not_required | ready | needs_authentication | expired | error
adapterVersion?
capabilities
localConcurrencyLimit
cloudConcurrencyLimit?
lastSeenAt?
```

The safe inventory fields originate in Conclave Workspace. Cloud stores the
synchronized projection and owns `schedulingState` and the optional Cloud
concurrency ceiling. Credential state and local readiness remain observations;
Cloud controls cannot change them. Effective execution still requires local
readiness, Cloud scheduling enabled, an online Workspace, active grants,
matching Project/Workstream policy, capability/model compatibility, and
available capacity.

Normal Worker rows expose Worker name, type, default model when useful, local
readiness, and Cloud scheduling state. `Auto` is the presentation for no
configured default model. Keep revisions, auth strategy, raw model allowlists,
permission names, credential references, local paths, and internal IDs out of
the normal row. An expanded detail view may show adapter version, capabilities,
concurrency limits, and a safe attention reason.

AX may enable, disable, or drain scheduling. AX may not create or locally
remove a Worker, set credentials, approve local permissions, install a CLI,
change an endpoint, or change local model configuration. For local attention,
AX says what needs attention and identifies the owning Workspace where the
user can complete it.

### `WorkspaceProjectGrantSummary`

```text
projectId
projectName
grantState            // active | suspended | revoked
scopeSummary
```

Cloud owns Project membership, Workspace Grants, their authorization scope,
and grant lifecycle. The card shows Project name and a concise grant state;
grant creation/revocation is available to authorized users. Detailed policy
remains in the existing grant-management flow where needed.

### `WorkspaceActivitySummary`

```text
activeAssignmentCount
lastSeenAt?
lastAssignmentAt?
```

Cloud assignment/run state and Workspace heartbeat state are the source for
these summary values. The card does not require a dedicated Activity tab for
these counts. A full audit timeline can be added later as an expandable
section, backed by real audit events.

## Cloud and desktop ownership

| Concern | Owner | AX treatment |
| --- | --- | --- |
| Workspace record, name, lifecycle, user role | Cloud | Show and manage according to role |
| Runtime credential, live connection, last-seen time | Cloud and paired runtime protocol | Show connected/offline and last seen |
| OS, architecture, app version | Workspace reports; Cloud stores safe facts | Show concise machine identity; diagnostics retain detail |
| Worker existence/configuration and Worker ID | Conclave Workspace | Show safe synchronized Worker projection |
| Provider credentials and authentication | Conclave Workspace secure storage | Never read or write from AX |
| Local permissions, CLI/prerequisite state, adapter health | Conclave Workspace | Show only safe readiness/attention summary |
| Local concurrency ceiling | Conclave Workspace | Display only when useful; Cloud cannot increase it |
| Cloud Worker scheduling state and Cloud concurrency ceiling | Cloud | AX scheduling controls operate here |
| Workspace-to-Project grants and Workstream policy | Cloud | AX owns authorization and grant controls |
| Active assignments, run attribution, audit | Cloud | Summarize activity; retain detailed audit views as needed |
| Work Root, local files, process state, logs | Conclave Workspace | Do not expose local paths or secrets in ordinary AX UI |

## Workspaces page behavior

- Application navigation calls the destination **Workspaces**, not Execution.
- `/workspaces` is the canonical collection route.
- `/workspaces/:workspaceId` resolves to the same collection page with that
  Workspace expanded, focused, and brought into view; it is not a separate
  five-tab detail page.
- One Workspace is expanded automatically. With two, both may be expanded.
  With three or more, expand the explicitly targeted Workspace or the first
  Workspace by default and let the user expand others.
- Each card groups Workers, Project access, the activity summary, and
  machine/settings sections. Workspace settings such as rename, reconnect,
  download, update status, and revoke live in the card's overflow menu or a
  focused dialog.
- Empty state explains that a Workspace is a computer where Workers run and
  offers **Add Workspace** as primary action and **Download Conclave
  Workspace** as secondary action.
- An unconnected Cloud Workspace offers the enrollment/connect-machine flow.
  Worker inventory appears only after the desktop has synchronized it.
- Home may summarize Projects, Workspaces, and Active Runs. It must not make
  Workers a separate top-level destination; a Ready Workers metric, if kept,
  opens or focuses the Workspaces page.
- Setup guidance is: add/connect a Workspace, configure Workers locally in
  Conclave Workspace, then create or grant Project access as needed.

## Routing compatibility contract

New navigation emits only `/workspaces` and `/workspaces/:workspaceId` for
Workspace management. During later migration, these historical Workspace
collection/detail routes redirect to their canonical equivalents:

```text
/execution                         -> /workspaces
/execution/workspaces              -> /workspaces
/hosts                             -> /workspaces
/execution/workspaces/:id          -> /workspaces/:id
/hosts/:id                         -> /workspaces/:id
```

Historical global Worker routes resolve to `/workspaces`; they do not render a
global Worker page:

```text
/execution/workers
/workers
/workspaces/workers
```

Account/profile routes are not Worker aliases and retain their independent
account/security behavior. Compatibility parsing can remain until a later
phase removes it deliberately.

## Known implementation gaps for later phases

The current AX implementation still has a two-tab Execution surface, a global
Workers tab, a separate Workspace detail page, and uses a `StudioAgent`
projection for Workspace overview cards. Some displayed Workspace counts are
currently hard-coded/defaulted rather than composed from V7 inventory,
runtime facts, grants, and assignment state. Current navigation also retains
historical route aliases and the app still carries both legacy and V7 Worker
models.

These are migration targets, not permission to remove code in Phase 1. Later
implementation phases must preserve run-composer/selector behavior until its
remaining consumers are audited and migrated to V7 Worker inventory.

## Phase 1 exit checks

- Workspaces is the only top-level AX execution-capacity resource.
- Worker visibility is nested within the owning Workspace.
- `StudioWorkspaceOverview` has runtime, Worker, Project Grant, and activity
  sections with explicit field ownership.
- Cloud scheduling state remains separate from Workspace local readiness.
- AX cannot use its Worker UI to mutate local credentials, permissions, or
  Worker configuration.
- Existing code remains intact until a later approved restructuring phase.
