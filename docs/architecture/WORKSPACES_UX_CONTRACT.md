# Conclave AX Workspaces UX and Data Contract

**Status:** Workspaces UI/model migration, Phase A6 compatibility handling, and pairing-first onboarding cleanup are implemented.

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

This contract defines the UX and frontend read model. The Workspaces page uses
one `StudioWorkspace` model and one `StudioWorker` V7 inventory projection.
Worker inventory, readiness, credential attention, Cloud scheduling, and
Enable/Disable/Drain controls live inside each owning Workspace card. Legacy
URLs continue to resolve to the canonical Workspaces page.

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
hasActiveRuntimeIdentity // internal compatibility classification; never display identity data
hostname?
operatingSystem?
architecture?
appVersion?
runtimeCapabilities?
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

Normal Worker rows expose Worker name, friendly type, default model, local
readiness, credential attention, and Cloud scheduling state. `Auto` is the
presentation for no configured default model. Keep revisions, auth strategy,
raw model allowlists, permission names, credential references, local paths,
and internal IDs out of the normal row. An expanded diagnostics view may show
adapter version, capabilities, concurrency limits, and safe local remediation
guidance. Worker configuration and authentication are explicitly managed in
Conclave Workspace on the owning computer.

AX may enable, disable, or drain scheduling. AX may not create or locally
remove a Worker, set credentials, approve local permissions, install a CLI,
change an endpoint, or change local model configuration. For local attention,
AX says what needs attention and identifies the owning Workspace where the
user can complete it.

The current Cloud Worker API is V7-shaped: `GET /api/v7/workers` reads the
safe inventory projection, `GET /api/v7/workers/:id/scheduling` reads the
Cloud scheduling state, and `POST /api/v7/workers/:id/scheduling/:action`
applies `enable`, `disable`, or `drain`. The former
`/api[/v2]/workspaces/:id/workers` catalog and desired-state routes are retired.
Workspace account and credential-profile APIs remain separate and are not
covered by this Worker-route retirement.

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

The Workspace list read model includes the runtime facts, latest available
last-seen time, count of non-removed V7 inventory Workers, and count of active
V7 assignments. AX refreshes the safe V7 Worker inventory separately to render
each Worker row; if that request fails, it retains the Cloud count instead of
showing a false zero. The desktop pairing claim supplies the Workspace name
and initial machine facts, which are persisted before the new Workspace is
returned to AX.

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

Pairing lifecycle audit is split by ownership boundary. Cloud records
`pairing.created` and `pairing.rejected` in account security audit events,
without storing pairing tokens. A successful claim records `pairing.claimed`,
`workspace.created`, and `runtime.enrolled` in the new Workspace audit stream.
Runtime removal and Workspace revocation record `workspace.unpaired` and
`workspace.revoked` respectively. Audit details may include pairing/Workspace/
runtime IDs and bounded machine facts, but never pairing tokens or runtime
credentials.

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
- Empty state says **No Workspaces connected**, explains that connecting a
  Conclave Workspace computer makes local Workers available to Projects, and
  offers **Connect Workspace** plus **Download Conclave Workspace**.
- Pairing creates a temporary owner-scoped intent, not a permanent Workspace.
  While unpaired, the desktop proposes the OS-friendly computer name as an
  editable Workspace display name (falling back to the cleaned hostname when
  unavailable). The user can change it before claiming the one-time code;
  Cloud creates the Workspace and runtime identity only after a successful
  claim. Existing paired Workspaces remain available during migration.
- New V7 execution Workspaces cannot be created with `POST /api/workspaces`;
  that endpoint returns `410 Gone` for the V7 authorization model. AX uses
  pairing intents. The retained non-V7 handler path exists only for historical
  compatibility and is not called by current AX.
- Legacy, unpaired Workspace placeholders are retained during migration. The
  Workspace read model identifies whether an active runtime identity exists;
  AX shows the old **Connect Machine** enrollment flow only for an unpaired
  placeholder. Pairing it keeps its existing Workspace ID and owner. A new
  pairing intent never adopts or renames that placeholder.
- An offline Workspace with an active runtime identity remains paired. AX
  keeps showing it as offline and does not ask it to claim a new code. Its
  saved runtime credential and Gateway reconnect path remain authoritative.
- Worker inventory appears only after the desktop has synchronized it.
- Home may summarize Projects, Workspaces, and Active Runs. It must not make
  Workers a separate top-level destination; a Ready Workers metric, if kept,
  opens or focuses the Workspaces page.
- Setup guidance is: install and configure Workers locally in Conclave
  Workspace, pair the installation, then grant Project access as needed.

## Migration and backward compatibility

Cloud migration `0028_workspace_pairing_intents.sql` is additive: it adds the
temporary pairing-intent table and the installation ID/index without changing
Workspace lifecycle rows or existing runtime credential hashes. Existing
paired desktops keep authenticating with their saved runtime credential and
reconnect through the same Workspace Gateway. They do not need to pair again
after an upgrade.

The selected placeholder policy is to keep legacy unpaired Workspace records
and their owner-scoped **Connect Machine** enrollment flow until connected.
Those records are not silently converted to a pairing intent or attached to a
different account. Runtime enrollment rejects an installation that is already
bound to a different active Workspace; explicitly unpaired/revoked installations
follow the existing recovery rules. New users use pairing intents, which do not
create a Workspace until a desktop claims one.

## Routing compatibility contract

New navigation emits only `/workspaces` and `/workspaces/:workspaceId` for
Workspace management. These historical Workspace collection/detail routes
resolve to their canonical equivalents:

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
/hosts/workers
```

Account/profile routes are not Worker aliases and retain their independent
account/security behavior. Legacy URLs are replaced in browser history with
their canonical URL. A Workspace ID focuses and expands that Workspace card on
the shared page.

## Implementation notes

The page now shows runtime facts, synchronized Workspace Workers, Project grant
counts, and activity inline in expandable cards. Worker rows are filtered
exclusively by `workspaceId`, are sourced from the V7 inventory, and do not
expose credential strategy or local permission details. There is no separate
Workers tab, global Worker page, or Workspace detail page. Grant counts are
refreshed from Project Workspace Grant read models; runtime activity continues
to use the current available assignment summary.

Workspace data comes from the Cloud Workspace read model, and Worker data comes
from the V7 inventory. The frontend no longer queries configured Worker or
Host collections. Worker-targeted notifications resolve the owning Workspace
when an inventory identity is available.

## Phase 1 exit checks

- Workspaces is the only top-level AX execution-capacity resource.
- Worker visibility is nested within the owning Workspace.
- `StudioWorkspaceOverview` has runtime, Worker, Project Grant, and activity
  sections with explicit field ownership.
- Cloud scheduling state remains separate from Workspace local readiness.
- AX cannot use its Worker UI to mutate local credentials, permissions, or
  Worker configuration.
- Historical route aliases remain supported during migration.
