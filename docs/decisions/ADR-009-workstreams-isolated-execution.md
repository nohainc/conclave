# ADR-009: Workstreams and Isolated Execution

**Status:** Accepted; Workstream isolation and Primary Workspace rules remain current under Architecture v7. Any Worker ownership or binding assumptions are superseded by ADR-012.
**Date:** 2026-09-24  
**Builds on:** ADR-008 / Architecture v5

## Context

Architecture v5 correctly separates Project collaboration from Workspace execution, but the implemented product still treats Chat as both:
- human conversation; and
- a potential execution trigger.

It also needs a stable isolation boundary so parallel Workstreams never mutate the same local working directory.

For a shared Project with several collaborators, this creates two product risks:

1. a normal discussion message may implicitly start AI work;
2. simultaneous AI work can corrupt or invalidate a shared checkout.

The Workspace runtime already contains strong primitives for safe filesystem access and command policy. The missing architecture is a persistent collaboration/execution unit that owns isolated mutable local state.

## Decision

Introduce **Workstream** as the unit of collaborative work inside a Project.

A Workstream contains:
- Discuss;
- Work;
- a Brief;
- Lead/access policy;
- default Workflow;
- Primary Workspace;
- configured Worker execution policy;
- persistent isolated working directory.

### Discuss

Discuss is human collaboration only.

No Discuss message may create/resume a Goal or Run as a side effect.

### Work

AI execution begins only through an explicit Work Request.

A Work Request snapshots a versioned Workflow and creates a Run.

### Mutable state

A Workstream uses one persistent local working directory on one Primary Workspace.

Stateful Workflow steps:
- execute only on the Primary Workspace;
- require an exclusive execution lease;
- carry a fencing token;
- are serialized per Workstream directory.

The directory is derived only from immutable Project ID + Workstream ID and never from display names or Workspace ID.

Workers manage any repositories inside the directory. Stateless read/research/review steps may run concurrently on other eligible Project Workspaces when their workflow context allows it.

### Recovery

Conclave preserves the Workstream directory across Work Requests and failures but does not initially promise automatic Git checkpoint/rollback semantics.

Workers/users use normal Git mechanisms to commit, synchronize, recover, and integrate repository state.

## Consequences

### Positive
- human discussion cannot accidentally trigger paid or mutating AI work;
- multiple team members can work safely in parallel on different Workstreams;
- one machine can execute multiple isolated Workstreams;
- every AI iteration has explicit requester/workflow/configured-Worker attribution;
- Workstream renames and Project renames never affect local execution paths;
- Workspace re-enrollment can reuse local Workstream data;
- audit remains attributable to Project/Workstream/Worker identity.

### Tradeoffs
- Workstream becomes a significant domain object;
- runtime must manage persistent Workstream directories and marker validation;
- repository recovery becomes a Worker/user Git responsibility;
- stateful concurrency is intentionally serialized within one Workstream;
- Workflow definitions need versioning;
- additional Durable Object/D1 coordination is required.

## Rejected alternatives

### Keep Chat and add a second nested AI Chat

Rejected because two nested generic Chats do not express different semantics strongly enough. Discuss and Work have different authorization and side-effect rules.

### Conclave-managed Source/repository registry

Deferred because it adds setup and repository-governance complexity that is not required for isolated AI work. Workers can clone and manage repositories inside the Workstream directory.

### Use Project/Workstream display names in local paths

Rejected because users may rename Projects or Workstreams at any time, including during active execution.

### Use Workspace ID in local paths

Rejected because Workspace enrollment identity is replaceable. Re-enrolling the same local installation must not orphan existing Workstream data.

### Allow simultaneous stateful mutation of one Workstream directory

Rejected because multiple Workers mutating the same local state concurrently would create nondeterministic filesystem behavior.

## Core invariant

> **A Workstream is the owner of one isolated persistent local working directory. Discuss is side-effect free; Work is explicit; stateful work is isolated and serialized; path identity uses immutable Project and Workstream IDs only.**
