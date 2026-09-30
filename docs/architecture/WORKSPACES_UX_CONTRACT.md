# Conclave AX Workspaces UX and Data Contract

**Status:** Current AX read-only Workspace read model; local lifecycle and management are defined by [ADR-014](../decisions/ADR-014-workspace-desktop-lifecycle.md).

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
- Workers are visible in AX, but have no independent top-level page or global
  inventory destination. Normal AX Workspace UI is read-only for runtime and
  local Worker lifecycle state.
- Workers are created, authenticated, permissioned, and removed locally in
  Conclave Workspace. AX never configures their local execution environment.
- Project access is managed as a Workspace Grant in AX. A Workspace can be
  granted to multiple Projects; it is not paired separately for each Project.
- Stateful Workstreams remain restricted to their Primary Workspace. Stateless
  work may use another Workspace only when its grant and execution policy allow
  it.

This contract defines the UX and frontend read model. The Workspaces page uses
one `StudioWorkspace` model and one `StudioWorker` V7 inventory projection.
Worker inventory and readiness attention live inside each owning Workspace
card. Actual Worker usage is configured in Project Workstreams. Legacy
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
workerTypeId
workspaceId
status               // ready | needs_attention | disabled | removed
readinessState       // independent package health; never replaced by disabled
attentionReasonCode? // set for actionable non-ready states
adapterVersion?
capabilities
localConcurrencyLimit
lastSeenAt?
```

The safe inventory fields originate in Conclave Workspace. `status` is the
compatibility activation/dispatch projection; `readinessState` remains the
independent package health result, including while the Worker is disabled.
Both are local observations; Cloud cannot change them. Cloud
scheduling state and limits are separate Cloud-owned controls and do not appear
in the Workspace readiness inventory.

The projection may also include a supported CLI version and discovered
non-sensitive model/capability metadata. The current implementation reports
adapter version and adapter-declared capabilities; CLI version and discovered
models are omitted until Workspace has a safe, validated source for them. AX
derives the fixed product label from `workerTypeId`. Keep auth strategy,
credential status/references, local permission names, local paths, model
defaults/allow-lists, tokens, API keys, and auth files out of Cloud inventory.
Raw command output is never an attention reason; use stable reason codes.
Worker configuration and authentication remain in Conclave Workspace.

The Workspaces page stays operational and read-only. AX may not create/remove
a local Worker, set credentials, approve local permissions, install a provider tool,
change an endpoint, or repair the runtime connection. Worker usage controls
belong to Workstream Execution settings and cannot change the Workspace's local
readiness or permissions.

The current Cloud Worker API is V7-shaped: `GET /api/v7/workers` reads the
safe readiness projection. Cloud scheduling APIs remain available for
Cloud-owned controls, while normal Worker usage is selected from Workstream
Execution settings. The former
`/api[/v2]/workspaces/:id/workers` catalog and desired-state routes are retired.
Workspace account and credential-profile APIs remain separate and are not
covered by this Worker-route retirement.

AX Workspaces is an operational read surface. It may show machine status,
Workers, connection mode, version, last seen, activity, and Project-facing
information. Pairing intent creation, Connect Machine, repair/re-pair, local
Workspace lifecycle actions, and local Worker setup are not part of the AX UX.
Project/Workstream owners and collaborators choose actual usage in each
Workstream's Execution settings.

### `WorkstreamWorkerUsagePolicy`

~~~json
{
  "version": 1,
  "fallbackPolicy": "configured_only",
  "roles": {
    "implementer": {
      "workerId": "stable-worker-id",
      "fallbackWorkerIds": [],
      "model": "provider-model-id",
      "cloudConcurrencyLimit": 1
    }
  }
}
~~~

AX stores this versioned policy in Cloud. Worker IDs are checked against active
Project Workspace Grants. Policy selection controls scheduling enablement,
primary/fallback ordering, model, and the Cloud concurrency ceiling; the
Workspace's local readiness and concurrency remain execution safety checks.
A Workstream assignment without a role mapping is not dispatched. With
`configured_only`, only listed Workers are considered. With
`configured_then_any`, listed Workers are preferred and other eligible,
Cloud-enabled Workers may be used as fallback.

Connection mode is read-only transport information. Render the display-ready
mode as `Connected · WebSocket` or `Connected · HTTPS fallback`; the fallback
mode may explain that WebSocket is unavailable while work can continue. It
does not expose controls for selecting a transport or imply a human management
session is valid.

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
| Workspace record, name, lifecycle, user role | Cloud with desktop-authenticated owner actions | Show read-only operational state in Workspaces |
| Runtime credential, live connection, last-seen time | Cloud and paired runtime protocol | Show connected/offline and last seen |
| OS, architecture, app version | Workspace reports; Cloud stores safe facts | Show concise machine identity; diagnostics retain detail |
| Worker existence/configuration and Worker ID | Conclave Workspace | Show safe synchronized Worker projection |
| Provider credentials and authentication | Conclave Workspace secure storage | Never read or write from AX |
| Local permissions, CLI/prerequisite state, adapter health | Conclave Workspace | Show only safe readiness/attention summary |
| Local concurrency ceiling | Conclave Workspace | Display only when useful; Cloud cannot increase it |
| Cloud scheduling state and concurrency limits | Cloud | AX selects them in Workstream Execution settings |
| Workspace-to-Project grants and Workstream usage policy | Cloud | AX owns authorization, Worker role/model/fallback choices, and limits |
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
- Empty state says **No Workspaces connected**, explains that installing
  Conclave Workspace and signing in on that computer will register it
  automatically, and offers **Download Conclave Workspace**. Normal AX no
  longer creates pairing codes.
- Target onboarding is desktop-authenticated registration, not AX pairing:
  the user signs in from Conclave Workspace, confirms the OS-friendly computer
  name, and the desktop registers/recovers its installation using the human
  management session. Cloud creates or restores the Workspace/runtime only for
  the authenticated owner. Existing pairing remains as a migration path until
  supported old desktop releases age out.
- New V7 execution Workspaces cannot be created with `POST /api/workspaces`;
  that endpoint returns `410 Gone` for the V7 authorization model. Current AX
  has no pairing-intent creation API or pairing action. Cloud keeps the legacy
  pairing handlers only for older supported desktop releases during migration.
- Legacy, unpaired Workspace placeholders remain visible as read-only records
  during migration. AX does not offer **Connect Machine** or another pairing
  action for them. Desktop authenticated registration creates or recovers a
  Workspace only for the authenticated owner.
- An offline Workspace with an active runtime identity remains paired. AX
  keeps showing it as offline and does not ask it to claim a new code. Its
  saved runtime credential and Gateway reconnect path remain authoritative.
- If the desktop is missing/rejected for its runtime credential, it uses its
  human desktop session over HTTPS to inspect ownership and recover/rotate the
  runtime credential. Normal recovery does not require AX and does not expose a
  pairing repair action. An installation owned by a different User is an
  explicit ownership conflict and is never transferred silently.
- Worker inventory appears only after the desktop has synchronized it.
- Home may summarize Projects, Workspaces, and Active Runs. It must not make
  Workers a separate top-level destination; a Ready Workers metric, if kept,
  opens or focuses the Workspaces page.
- Setup guidance is: install and configure Workers locally in Conclave
  Workspace, sign in to register the installation, then grant Project access
  as needed.

## Migration and backward compatibility

Cloud migration `0028_workspace_pairing_intents.sql` is additive: it adds the
temporary pairing-intent table and the installation ID/index without changing
Workspace lifecycle rows or existing runtime credential hashes. Existing
paired desktops keep authenticating with their saved runtime credential and
reconnect through the same Workspace Gateway. They do not need to pair again
after an upgrade. Pairing endpoints and their table remain compatibility
surface for older supported desktop releases; remove them only after release
telemetry and the published compatibility window show those clients have
migrated. No such completed release window is recorded yet.

The selected placeholder policy is to retain legacy unpaired Workspace records
until migrated or retired. They remain read-only in AX and are not silently
converted or attached to a different account. Runtime enrollment rejects an
installation already bound to another active Workspace. New installations use
desktop authenticated registration and recovery.

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


## ADR-013 target state

The Workspaces page remains an operationally read-only view of the user's
registered machines and synchronized Workers. It may display
`WebSocket` or `HTTPS fallback` as the observed connection mode. Workspace
registration, recovery, sign-in, local Worker management and transport
selection live in Conclave Workspace. Project membership, Workspace Grants and
Workstream Worker usage policies remain Cloud/AX collaboration concerns. AX
configures role-to-Worker and model selection, fallback behavior, and Cloud
concurrency; Workspace supplies readiness and enforces local limits.

See [ADR-013](../decisions/ADR-013-desktop-auth-and-dual-transport.md).

## Desktop lifecycle visibility contract

ADR-014 refines the desktop side of this UX contract:

- **Signed out:** Conclave Workspace shows a dedicated Sign in shell only; the
  Workspace and Workers tabs are hidden.
- **Signed in / disconnected:** show account/computer identity and **Connect
  Workspace**. Do not expose Worker management yet.
- **Connected / unlocked:** show the normal **Workspace** and **Workers** tabs.
- **Connected / locked:** keep the runtime online but hide management details
  until native local authentication succeeds.
- **Connected / reauth required:** runtime execution may continue, but the user
  must reauthenticate as the same Workspace owner before management controls
  return.
- Human Sign in does not itself create/recover the runtime after the ADR-014
  migration; **Connect Workspace** does.
- A connected installation cannot switch to another Conclave user. Explicit
  Disconnect and Release ownership are required before an ownership change.
- Connected installations may launch/reconnect automatically at OS login. AX
  shows read-only machine and Worker readiness. Worker usage policy remains
  editable in AX Workstreams.

See [ADR-014](../decisions/ADR-014-workspace-desktop-lifecycle.md).
