# ADR-019: Per-user Workflow execution configuration

**Status:** Accepted  
**Date:** 2026-10-08  
**Supersedes:** ADR-016's Thread execution bindings and fallback policy. Workspace
readiness, Space grants, scheduling permissions, and local safety ownership remain.

Conclave owns fixed, versioned Workflow definitions. Users configure how those
Workflows execute globally, independent of Space and Thread selection.

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

User preferences store enabled state, sparse Worker/model/effort defaults, and
sparse fixed-step overrides. Omission means Automatic/inheritance. Definitions,
structure, prompts, and internal contracts are never copied into preferences or
made editable. Profile capabilities determine allowed model/effort combinations.
Offline Workers remain configured; execution admission independently rechecks
ownership, readiness, capabilities, grants, permissions, and Workspace eligibility.

Cloud resolves these choices at request acceptance. Automatic Worker selection
must admit the entire workflow in one Workspace. Automatic model/effort means
null (Profile/CLI default), not a guessed provider choice. Each accepted step
freezes Worker, signed Profile identity/release, nullable model/effort, and Workflow
identity/version in the immutable request snapshot. WorkflowRun and StepRun expose
that accepted configuration; Worker turns record actual invocation evidence.
Retries dispatch the snapshot and cannot silently substitute Worker or Profile.
Changing preferences, ownership, availability, or current catalog metadata never
rewrites accepted history.

Workflows is the sole global execution editor. Thread settings retain authored
context and the initial Workflow selection, with no Worker/model/effort/fallback
writes or scheduling side effects. The current composer's layout is retained as
a display of global choices; it submits authored content and Workflow identity,
not execution overrides. Reset always resolves Automatic without consulting old
Thread or composer settings.

The future extension is explicit and not implemented:

```text
User Workflow Configuration
       ↓
Thread preference       [future]
       ↓
Composer override       [future]
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
