# Durable Work Execution

Conclave Cloud uses Cloudflare Workflows to coordinate long-running Work
Requests. Workflow checkpoints support retries, waits, and recovery. D1 and R2
remain the application system of record; Workflow state is execution
coordination state and does not replace persisted domain records.

## Lifecycle

A Work Request is created for a Workstream under the frozen [Work v1
contract](WORK_V1_CONTRACT.md). Cloud records the request, workflow snapshot,
run, task, and assignment state. The Workflow advances the request through its
configured steps and waits for Workspace execution, evidence, approvals, or
other required outcomes before completing it.

Each checkpoint carries the small validated state needed by the next stage.
Workflow replay must not depend on module-level mutable state, wall-clock
values, or an in-memory task cursor. Side effects occur inside named durable
steps, with bounded retry and timeout policies.

## Identity and recovery

Workflow instances use deterministic identifiers derived from validated
idempotency data. Repeated creation resolves to the existing persisted Work
Request and instance rather than creating duplicate active work. External event
payloads are validated at the API boundary and again before they affect
Workflow state.

Cloud domain rows remain authoritative for ownership, authorization, and Work
status. On recovery, Cloud correlates Workflow state with persisted Work
records and execution results. A missing execution service or inconsistent
state must fail visibly; a checkpoint alone cannot establish successful Work.

## Execution boundary

The Cloudflare Workflow invokes the configured execution service for work that
requires it. That service coordinates the current Worker catalog, assignment
state, persistence, and Workspace runtime bridge. Provider CLI execution
occurs in Conclave Workspace through the generic CLI Worker Engine and a
verified Tool Profile. Cloud does not execute a provider CLI.

The runtime boundary and message ownership are defined by the [Protocol
Boundaries contract](../architecture/PROTOCOL_BOUNDARIES.md). User-visible
Workflow behavior is defined by the [Work v1 contract](WORK_V1_CONTRACT.md).
Queues or additional coordination services require a concrete need beyond the
current Workflow and Workspace runtime model.
