# ADR-016: AX-Owned Worker Usage Policy

**Status:** Accepted for implementation  
**Date:** 2026-09-28  
**Builds on:** ADR-012, ADR-014, ADR-015  
**Supersedes:** AX Workspaces read-only operational guidance only where it
would prevent Project/Workstream execution policy management.

## Context

Conclave Workspace owns machine-local execution readiness: it knows whether
ChatGPT/Codex and Gemini/Antigravity can run on that machine. Actual use of a
Worker is a Project decision. AX and Cloud already own Project membership,
Workspace grants, Workstream policy, scheduling state, model selection, and
assignment dispatch, but the Workstream UI does not expose the complete choice.

Mixing Step/model/scheduling policy into local Worker setup makes the machine
runtime appear to own Project intent and makes remote collaboration depend on
opening the desktop application.

## Decision

1. **Workspace reports readiness.** The Worker checks its provider tool and
   reports Ready/attention/disabled. Workspace enforces Worker release
   admission, local permissions, process execution, and local safety limits.
   Workspace does not choose Project or Workstream use, canonical Step
   bindings, model, fallback policy, or Cloud-side capacity limits.
2. **AX owns actual use.** In a Workstream Work config, an authorized Project
   member selects a default built-in Workflow and binds `direct` and each
   canonical Work v1 StepKind to a Workspace Worker. A binding may also set a
   model, one fallback Worker, and additional Step instructions.
3. **Cloud enforces the config.** The scheduler applies the selected Step
   binding, active Project grant, Workspace online state, local readiness,
   Cloud scheduling state, model policy, capacity, and assignment permissions.
   The Workspace continues to enforce its local permission and concurrency
   boundaries when executing.
4. **A missing Step binding fails closed.** A Workstream assignment is not
   dispatched until AX has a binding for its canonical Step. Cloud considers
   only the selected primary and optional fallback Workers.
5. **The desktop is not required for policy management.** Workspace inventory
   remains visible as operational status. AX Workstream configuration is the
   user-facing place to decide where and how work runs.

The shared core owns the closed StepKind set and versioned built-in Workflow
catalog. Cloud stores the Workstream configuration and snapshots the selected
Workflow, resolved Step bindings, request, instructions, and internal Step
Prompt Profile versions on each Work Request. Cloud composes each prompt from
that immutable snapshot and the fixed handoff contract. Prompt Profiles are
Conclave implementation data, not a user-editable template or macro language.
The [Work v1 Contract](../specifications/WORK_V1_CONTRACT.md) is authoritative
for catalog, configuration, snapshot, and prompt semantics.

## Workstream Work config

~~~json
{
  "defaultWorkflowId": "full_cycle",
  "bindings": {
    "direct": { "workerId": "stable-worker-id" },
    "research": { "workerId": "stable-worker-id" },
    "plan": { "workerId": "stable-worker-id" },
    "implement": { "workerId": "stable-worker-id" },
    "test": { "workerId": "stable-worker-id" },
    "verify": {
      "workerId": "stable-worker-id",
      "model": "provider-model-id",
      "fallbackWorkerId": "another-stable-worker-id",
      "additionalInstructions": "Check the migration path."
    }
  }
}
~~~

The selected Worker's Workspace is derived from its stable Worker ID and
validated against an active Project Workspace Grant. Binding IDs are closed to
`direct`, `research`, `plan`, `implement`, `test`, and `verify`. Local
credentials, permission names, paths, and raw CLI output are never part of this
config. Conclave does not add arbitrary task roles, dependencies, or fallback
to any eligible Worker.

## Migration and compatibility

The former role-based policy table is dropped and recreated for the fixed
Workstream Work config; development Workstreams must be configured again.
Existing in-flight assignments continue using their immutable assignment
snapshots. Direct non-Workstream scheduler callers retain their current
selection behavior.

Cloud stores the versioned policy separately from local Worker inventory.
Workspace inventory remains safe operational metadata and is not a source of
Project intent.
