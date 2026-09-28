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

Mixing role/model/scheduling policy into local Worker setup makes the machine
runtime appear to own Project intent and makes remote collaboration depend on
opening the desktop application.

## Decision

1. **Workspace reports readiness.** It keeps provider authentication, adapter
   admission, local permissions, process execution, and local safety limits.
   It reports Ready/attention/disabled for each fixed Worker Type. It does not
   choose Project or Workstream use, task roles, model, fallback policy, or
   Cloud-side capacity limits.
2. **AX owns actual use.** In a Workstream Execution policy, an authorized
   Project member maps a task role to a Workspace Worker, selects the model,
   orders an optional fallback Worker, chooses fallback behavior, and sets a
   Cloud concurrency ceiling.
3. **Cloud enforces the policy.** The scheduler applies the Workstream role
   binding, active Project grant, Workspace online state, local readiness,
   Cloud scheduling state, model policy, capacity, and assignment permissions.
   The Workspace continues to enforce its local permission and concurrency
   boundaries when executing.
4. **A missing role mapping fails closed.** A Workstream assignment is not
   dispatched until AX has a mapping for its role. `configured_only` tries
   only the selected primary and ordered fallback Workers. `configured_then_any`
   prefers those Workers and then may use any otherwise eligible, Cloud-enabled
   Worker covered by the Workstream's active Project grants.
5. **The desktop is not required for policy management.** Workspace inventory
   remains visible as operational status. AX Workstream configuration is the
   user-facing place to decide where and how work runs.

## Policy contract v1

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

The selected Worker's Workspace is derived from its stable Worker ID and
validated against an active Project Workspace Grant. Local credentials,
permission names, paths, and raw CLI output are never part of this policy.

## Migration and compatibility

Workstreams without an explicit role mapping no longer receive implicit
Workstream Worker selection. Owners/collaborators configure mappings in AX
before those Workstreams dispatch new assignments. Existing in-flight
assignments continue using their immutable assignment snapshots. Direct
non-Workstream scheduler callers retain their current selection behavior.

Cloud stores the versioned policy separately from local Worker inventory.
Workspace inventory remains safe operational metadata and is not a source of
Project intent.
