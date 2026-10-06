# ADR-009: Workstreams and Isolated Execution

**Status:** Accepted; current Workstream isolation and Primary Workspace rules.
Worker ownership and execution boundaries follow [ADR-012](ADR-012-workspace-owned-local-workers.md), [ADR-015](ADR-015-first-party-worker-v1-contract.md), and [Architecture v8](../architecture/ARCHITECTURE_V8.md).
**Date:** 2026-09-24  
**Builds on:** ADR-008

## Context

Project collaboration and machine execution need a stable isolation boundary so
parallel Workstreams never mutate the same local working directory. Discuss is
human collaboration; Work is an explicit execution request.

For a shared Project with several collaborators, this creates two product risks:

1. a normal discussion message may implicitly start AI work;
2. overlapping Work Requests can mutate or inspect inconsistent state in the
   same local Workstream directory.

The Workspace runtime already contains strong primitives for safe filesystem access and command policy. The missing architecture is a persistent collaboration/execution unit that owns isolated mutable local state.

## Decision

Introduce **Workstream** as the unit of collaborative work inside a Project.

A Workstream contains:
- Discuss;
- Work;
- a Brief;
- access policy;
- default Workflow;
- Primary Workspace;
- logical Worker bindings for Work (`direct`) and Workflow Steps;
- persistent isolated working directory.

### Discuss

Discuss is human collaboration only.

No Discuss message may create/resume a Work Request or Run as a side effect.

### Work

AI execution begins only through an explicit Work Request.

A Work Request snapshots a versioned Workflow and creates a Run.

### Mutable state

A Workstream's stateful execution uses one persistent local working directory
on its Primary Workspace. Workspace resolves the directory from immutable
Project and Workstream IDs under its Work Root.

Each Work Request containing a stateful Step acquires one exclusive
Workstream runtime lease before execution. The lease is held for the Work
Request's lifetime, carries a monotonically increasing fencing token, and
serializes stateful Work Requests for that Workstream. All stateful Steps run
on the Primary Workspace. Workspace validates the lease and fencing token
before mutating the ID-derived directory.

Research and Plan are stateless, read-only Steps. They may run on another
eligible Workspace with an active Project grant and may run concurrently; they
do not mutate the Workstream directory. A Work Request that includes later
stateful Steps still holds its Workstream lease until it reaches a terminal
state.

The Workspace starts the generic CLI Worker Engine, which resolves a signed
Tool Profile and invokes the provider CLI. The provider CLI manages Git
repositories inside the directory. Conclave does not register or provision
repositories, create Git commits, or restore Git state after failed Work.

### Recovery

Conclave preserves the Workstream directory across Work Requests and failures
but does not restore Git state after failed Work.

Users and provider CLIs use normal Git mechanisms to commit, synchronize,
recover, and integrate repository state. Changing Primary Workspace does not
copy the directory; local data remains on its original Workspace.

## Consequences

### Positive
- human discussion cannot accidentally trigger paid or mutating AI work;
- multiple team members can work safely in parallel on different Workstreams;
- one machine can execute multiple isolated Workstreams;
- every AI iteration has explicit requester, Workflow, and logical Worker attribution;
- Workstream renames and Project renames never affect local execution paths;
- Workspace re-registration can reuse local Workstream data;
- audit remains attributable to Project/Workstream/Worker identity.

### Tradeoffs
- Workstream becomes a significant domain object;
- runtime must manage persistent Workstream directories and marker validation;
- repository recovery remains a provider CLI/user responsibility;
- stateful Work Requests are intentionally serialized within one Workstream;
- Workflow definitions need versioning;
- additional Durable Object/D1 coordination is required.

## Rejected alternatives

### Keep Chat and add a second nested AI Chat

Rejected because two nested generic Chats do not express different semantics strongly enough. Discuss and Work have different authorization and side-effect rules.

### Conclave-managed Source/repository registry

Deferred because it adds setup and repository-governance complexity that is not
required for isolated AI work. Provider CLIs can clone and manage repositories
inside the Workstream directory.

### Use Project/Workstream display names in local paths

Rejected because users may rename Projects or Workstreams at any time, including during active execution.

### Use Workspace ID in local paths

Rejected because Workspace registration identity is replaceable. Registering the same local installation again must not orphan existing Workstream data.

### Allow simultaneous stateful Work Requests for one Workstream

Rejected because multiple stateful Work Requests acting on the same local state
concurrently would create nondeterministic filesystem behavior.

## Core invariant

> **Local work belongs to Project + Workstream identity, not to names, Workspace registration identity, or repositories. Workspace resolves the ID-derived path; a request-scoped lease fences stateful execution; the generic Engine and signed Tool Profile run the provider CLI inside that boundary.**
