# User Workflow Configuration v1

Global per-user preferences are separate from Conclave-owned Workflow definitions
and Space/Thread authored context. Preferences
are keyed by authenticated user and stable Workflow ID, not definition version.
The newest definition validates step IDs. Definition graphs, prompts, labels,
and capabilities are never copied into preferences.

```json
{
  "schemaVersion": 1,
  "workflowId": "full_cycle",
  "enabled": true,
  "defaults": { "worker": "worker-id", "model": "model-id", "effort": "high" },
  "stepOverrides": { "verify": { "worker": "review-worker-id" } }
}
```

Omitted selections mean Auto/inherit. Writes normalize null and `Auto` to
omission and remove empty step overrides. An absent row means enabled with all
choices Auto. Step overrides inherit each omitted field from workflow defaults.
Auto in a step clears that step's explicit choice and inherits the default; it
does not bypass an explicit workflow default. Effort strings are Profile-owned,
not a fixed provider enum. Worker IDs identify user-owned inventory entries.

## Authenticated human API

- `GET /api/user/workflow-configurations`: versioned sparse collection.
- `GET /api/user/workflow-configurations/:workflowId`: sparse collection scoped
  to one known Workflow (empty when unconfigured).
- `PUT /api/user/workflow-configurations/:workflowId`: replace one complete v1
  preference; returns `{ configuration }`.
- `DELETE /api/user/workflow-configurations/:workflowId`: reset; returns the
  default v1 configuration and deletes the row.

No user ID is accepted in the payload. Existing human authentication and cookie
mutation origin protection apply. Model/effort validation uses owned Worker
inventory and published, non-revoked Profile capabilities. Auto Worker plus an
explicit model/effort requires at least one supporting owned Worker. Offline
readiness does not invalidate preferences. Unchanged selections are retained
when inventory/Profile metadata is unavailable; execution must still perform
its own current authorization, grant, capability and readiness checks.

## Resolution boundary and rollout

Core exposes a pure definition + user-default + step-override resolver; it does
not pick a runnable Worker or inject provider defaults. AX has typed immutable
configuration models and a dedicated typed data-source interface implemented by
its authenticated API client. Phase 2 adds the global Workflows page and session query cache; see
[AX server state](../architecture/AX_SERVER_STATE.md#global-workflows-page).
Phase 4 applies this resolution at preflight and request acceptance. Disabled
Workflows cannot execute. Thread bindings no longer provide execution defaults.

Future Thread and composer layers can overlay the same sparse selection type
at the resolver boundary without changing user preference storage. Neither
future layer is introduced here. Effective configurations are frozen at acceptance; historical requests are never
rewritten when preferences change.

Apply additive v8 migration `0018_user_workflow_configurations.sql` before
serving these endpoints. It creates a user-owned table with cascading user
removal and a composite primary key. No existing configuration or Work Request
is migrated or rewritten; this is part of the v8 baseline, with no legacy API.

## Workflow editor

Selecting a card or Edit opens the Workflow editor on the global Workflows page.
Default execution contains Worker, model, and effort pickers. Advanced contains
a numbered list of the definition's fixed steps in definition order. Each row
summarizes inheritance or its explicit execution choices, and expands to
Execution controls: Use workflow defaults or Override. Per-field Automatic
inherits the corresponding workflow default, with the inherited value shown.
An effort-only override does not copy the default Worker or model into storage.
Empty overrides are omitted rather than recording an override-mode flag.

Changing Worker clears explicit model and effort choices; changing model clears
explicit effort. Inherited fields remain inherited. Options and validation use
owned Worker/Profile metadata, including model-specific supported efforts.
Auto Worker choices require a coherent model/effort combination on at least one
Worker Profile. Incompatible effective defaults or step choices are identified
inline and block Save; a default change may require correcting a step override.
Cloud independently validates each write through the existing v1 API.

Offline readiness is separate from capability compatibility. Offline Workers
remain selectable and labeled. Missing saved Workers and model/effort choices
remain visible instead of silently reverting to Automatic. Unchanged selections
with missing inventory or Profile metadata can be preserved, matching the Cloud
intent rule. Removing a step override can also restore already-saved workflow
defaults while metadata is unavailable; changed combinations require supported
metadata. The open editor
observes the shared Worker query, so inventory refresh revalidates the draft.

Reset restores the whole workflow through the authenticated reset API. Reset
step to inherited values and Use workflow defaults remove only that step's local
override; Save commits the resulting sparse configuration. Cancel discards the
local draft. Failed writes retain the draft and expose the API error for explicit
retry. Mutations update the shared preference cache without a follow-up GET.

Advanced execution preferences are exposed only in this editor. Users cannot
create Workflows, add/remove/reorder steps, edit system prompts, or alter internal
contracts. Conclave owns the definitions and structure; users own execution
preferences. Phase 3 introduces no schema or API migration.

## Execution resolution and snapshots

Cloud resolves current-user preferences for both validation and submission.
Defaults are overlaid by sparse step overrides. Auto Worker is chosen from owned
inventory through existing Space grants, Thread permissions, Profile capability,
readiness, and Workspace eligibility rules. Resolution tests whole-workflow
feasibility in one Workspace before freezing Auto choices. An explicit offline,
missing, or incompatible Worker fails admission; it is never silently replaced.
Auto model and effort remain null, meaning the signed Profile/provider CLI default;
Conclave does not guess a provider model or effort.

Every new accepted Work Request stores `stepExecutionConfigs` keyed by definition
step kind in its immutable v1 snapshot. Each value records schema version, Worker
ID, Profile ID/release version, nullable model/effort, and Workflow ID/version.
Manual WorkflowRun/StepRun read models expose these same accepted snapshots as
`executionConfigs`/`executionConfig`, including queued steps before dispatch.
Worker turns retain actual invocation evidence separately. Graph executions use
the same accepted Work Request step snapshot and scheduler admission boundary.
Retries and request replays use the frozen snapshot, not current preferences.
The scheduler requires the recorded Worker and Profile release and uses recorded
model/effort even when null. Profile changes or revocation fail admission rather
than substituting a release. Existing historical requests remain unchanged; no
missing Profile identity is reconstructed from today's inventory.

The composer's existing layout displays global execution choices without editing
or submitting an override. AX sends the authored request, attachments, Workflow
identity, and idempotency key. Cloud rejects the removed `executionSelection`
claim. Unconfigured Workflows and reset resolve Automatic consistently, with no
legacy Thread binding or composer fallback. Thread settings retain authored
instructions and initial Workflow selection, but no execution configuration or
implicit Worker scheduling writes. Generic Settings remains account/application
configuration. Workflows is the authoritative global execution editor.

## Migration and cleanup

Apply `0018_user_workflow_configurations.sql` and
`0019_thread_execution_configuration_cleanup.sql` before updated AX/Cloud.
0018 creates user-owned sparse preferences. 0019 removes obsolete execution
choices/labels/fallbacks from mutable Thread configuration, preserving authored
Thread and step instructions and initial Workflow selection. Shared Thread choices
cannot be assigned unambiguously to one user, so they are not copied into global
preferences. With no saved user preferences, execution resolves Automatic.

Accepted request snapshots and historical runs are never migrated or backfilled.
The snapshot's versioned execution data remains immutable. Old API clients trying
to write Thread execution fields or submit `executionSelection` receive 400; ship
AX and Cloud together. There is no compatibility alias or runtime fallback.
Historical read-only fields remain evidence, not a source for new execution defaults.

## Ownership and future extensions

```text
Workflow Definition
       ↓
User Workflow Configuration
       ↓
Execution Resolution
       ↓
WorkflowRun
       ↓
StepRun
```

```text
User Workflow Configuration
       ↓
Thread preference       [future]
       ↓
Composer override       [future]
```

Thread preference and composer override layers are not implemented. When added,
they may overlay the same sparse selection type before resolution, without schema
redesign or historical rewrites. See [ADR-019](../decisions/ADR-019-per-user-workflow-execution-configuration.md).

## Focused validation

Core resolver tests cover sparse Auto/default inheritance and fixed step overrides.
Cloud tests cover authenticated ownership/isolation, invalid capability combinations,
reset, unavailable Worker intent, runtime admission, immutable Run/Step snapshots,
Profile pinning, rejection of obsolete writes, and cleanup migration invariants.
AX tests cover Profile model/effort filtering, invalid combinations, editing/saving,
reset/inherit, inventory changes, navigation, session isolation, query deduplication,
cache reuse, and global preference projection into retained Thread controls.
Component validation is AX + Cloud and direct shared contracts. No Workspace,
Profile Lab, Public Site, native packaging, or full-repository run is required.
