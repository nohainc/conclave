# ADR-019: Per-user Workflow execution configuration

**Status:** Accepted; extended by shared Space overrides (see configuration specification)
**Date:** 2026-10-08  
**Supersedes:** ADR-016's Thread execution bindings and fallback policy. Workspace
readiness, Space grants, scheduling permissions, and local safety ownership remain.

Conclave owns fixed, versioned Workflow definitions. Users configure how those
Workflows execute globally, independent of Space and Thread selection.

```text
Workflow Definition
       ↓
User Workflow Configuration (Space owner)
       ↓
Space Workflow Configuration
       ↓
Execution Resolution
       ↓
WorkflowRun
       ↓
StepRun
```

User preferences store enabled state, explicit Worker defaults, sparse model/effort
defaults, and sparse fixed-step overrides. A step may omit Worker to inherit the
workflow default; model and effort omission means `Auto`. Definitions,
structure, prompts, and internal contracts are never copied into preferences or
made editable. Signed Profile execution options determine supported model/effort
combinations; legacy Worker/Profile capability arrays are ignored. Offline Workers
remain configured; execution admission independently rechecks ownership, readiness,
grants, permissions, and Workspace eligibility.

Cloud resolves owner-global defaults plus shared Space overrides at request acceptance.
Every enabled step must name a Worker in one Workspace; Cloud never chooses a
replacement Worker. `Auto` model/effort means null (Profile/CLI default), not a
guessed provider choice. Each accepted step
freezes Worker, signed Profile identity/release, nullable model/effort, and Workflow
identity/version in the immutable request snapshot. WorkflowRun and StepRun expose
that accepted configuration; Worker turns record actual invocation evidence.
Retries dispatch the snapshot and cannot silently substitute Worker or Profile.
Changing preferences, ownership, availability, or current catalog metadata never
rewrites accepted history.

Workflows is the sole editor for saved execution settings. Thread settings retain
authored context and the initial Workflow selection, with no Worker/model/effort/
fallback writes or scheduling side effects. For a one-step Workflow, the current
composer may submit a transient Worker/model/effort selection for that request;
Cloud validates and snapshots it without changing Space or user settings. Global
reset clears the Worker and uses `Auto` for model and effort without consulting
old Thread or composer settings.

The future Thread extension is explicit; the one-step composer layer is already
implemented as a current-request-only overlay:

```text
User Workflow Configuration
       ↓
Space Workflow Configuration
       ↓
Thread preference       [future]
       ↓
Composer override       [one-step, current request only]
```

Both layers can overlay the sparse selection type before execution resolution,
without changing preference persistence or rewriting snapshots. Neither is a
compatibility path for retired Thread bindings or next-turn API claims.

Migration 0018 adds user-owned preference persistence. Migration 0019 removes
obsolete execution fields from mutable Thread configuration while preserving
authored instructions. It does not guess a user from shared Thread preferences,
transfer them into global preferences, alter scheduling state, or rewrite accepted
requests. Apply both before serving the updated AX/Cloud contract. Unreleased v8
has no compatibility API for the removed configuration forms.

Validation is scoped to AX, Cloud, and directly affected shared Core/security
contracts. Workspace, Profile Lab, Public Site, and full repository validation
are unnecessary because this decision changes no local Engine or provider protocol.

The Space Workflows tab initializes from owner-global defaults. Saving replaces
one whole workflow for that Space; Reset restores inheritance. Every Thread and
requester uses this shared configuration. Only the Space owner may mutate it;
Space members may read it. Migration 0020 adds its persistence, without rewriting
accepted snapshots. Global Workflows and Workspaces are accessed through the
application menu rather than dedicated sidebar or rail buttons.

Workspace selection is part of the execution scope, stored separately from sparse
workflow preferences. Both Workflows views expose it. Only selected-Workspace
Workers and signed Profile execution options participate in editing, validation,
and runtime resolution. A confirmed switch atomically resets all scope preferences. Spaces
inherit the owner's global Workspace until explicitly forked; global switches
reset inheriting Spaces but preserve independent scopes. Returning a Space to
inheritance restores the current global configuration. Every Thread uses this
shared selection; accepted snapshots are unaffected.

Migration 0022 adds user/Space Workspace settings and converts old Space-wide Work
denials into per-workflow disabled flags before deleting the retired setting.
Workspace grants and member rights remain required. Owned Workspace selection
creates missing grants for inheriting/new owned Spaces, without broadening
existing grants or reactivating suspended/expired grants. Space Workspaces UI and
its connection API are removed; Workflows owns selection and enablement.

## Catalog refresh and selection intent

Saved global/Space Workflow preferences and transient Work-tab selections express
Worker/model/effort intent. Their optional `catalogRevision` records the observed
catalog; it is not an execution pin. Fresh catalog changes do not invalidate a
still-supported selection or mutate saved settings, inherited overrides, or
restored composer state. Removed models or unsupported efforts remain visible
and require an explicit replacement; stale or unavailable catalogs still block
new execution. The existing unchanged-unavailable preference preservation rule
continues to apply to saved settings.

Cloud validates effective choices against current authorized Worker capabilities
and records that catalog revision in each accepted request binding. Acceptance
rechecks the pinned bindings before persistence. Scheduler dispatch and retries
continue enforcing exact catalog revision matches. The Engine additionally
enforces Service-owned provider-catalog pins; static capabilities remain bound
by the admitted Profile. An accepted request is never rebased onto a newer
catalog. Auto values remain user intent
rather than being materialized into saved preferences.

No D1 migration or protocol version change is required. Existing observed
revisions in preferences and local view state remain readable; historical
request/assignment snapshots retain their original immutable revisions.
