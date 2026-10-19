# Parallel execution and queue management

Phase 7 makes queueing an explicit part of the assignment lifecycle. Cloud
persists and dispatches assignments even when the selected Worker is at its
effective capacity. The Workspace Service is the final admission authority:
it atomically reserves a local slot, starts one isolated Engine process per
assignment, and transfers a released slot to the next waiter without changing
the assignment identity.

## Effective capacity: one shared slot pool

Parallel execution is a single Workspace-wide total ("parallel slots", default
5, range 1-10), not a per-Worker count. Any Worker can use any free slot; the
user sees one "N of M slots in use" figure and sets one number.

The Workspace stores the total as `localConcurrencyLimit` on every Worker
record. Changing it (`execution.setParallelSlots`) rewrites every record and
advances each Worker revision. The Service applies only this total when
admitting work; `maxConcurrentAssignments` in the assignment payload is no
longer used to size the pool (Cloud grant and scheduling limits are enforced
at dispatch). Existing installations keep their stored value (3) until the user
changes it.

The `worker.inventory` payload also carries the total once as `parallelSlots`
(optional, 1-1024, additive in protocol 5.1). Cloud stores it on the Workspace
(`execution_workspaces.parallel_slots`, migration
`0070_workspace_parallel_slots.sql`, backfilled from the reported Worker
values) and the scheduler reads that single value, falling back to the
per-Worker `local_concurrency_limit` only for a Service that has not reported
it. The per-Worker field and column are a rollout-compatibility detail, not a
product concept: there is no hidden per-Worker cap, and the UI shows only the
Workspace total. Remove the per-Worker field once every deployed Service sends
`parallelSlots`. Deploy order: migration 0070, then Cloud, then the Workspace
app.

Cloud counts queued and active assignments for Worker load balancing. When
queueing is not allowed it rejects dispatch when the Workspace-wide active count
reaches the reported total, or when a Worker reaches its Cloud scheduling or
Space grant limit. Queued assignments are durable in
`worker_assignments.status = 'created'` and do not claim a provider process.
The Service owns the final slot reservation and is the only place that claims a
live process slot. Waiters are admitted first-in-first-out; one whose provider
session is busy is skipped rather than blocking the others.

## Workspace controls

The Workspace section owns the shared capacity selector, usage and queue counts;
Worker setup remains in the Workers section. Capacity is editable through local
IPC while the service is running, independently of Cloud connectivity. Raising
the limit immediately admits eligible waiters. Lowering it preserves running
assignments and admits no further work until capacity is available. Reset slots
remains a separate confirmed recovery action that stops running and waiting work.

Prevent sleep remains editable with the service running or stopped, independently
of Cloud connectivity. The saved preference applies while the service runs;
macOS changes are picked up within the service's five-second polling interval.

## Deadlines

`timeoutMs` is the provider/Engine execution deadline and starts after local
slot admission. `queueWaitTimeoutMs` is an independent deadline beginning when
the assignment enters the local queue. The default queue deadline is two
minutes. Cloud workflow polling and stale-assignment recovery use the queue
deadline before startup and the execution deadline after the explicit
provider-start acknowledgement.

## Isolation and cancellation

Every admitted assignment has its own Engine process, process ownership
record, event correlation IDs, and cancellation path. Durable provider session
locks serialize attempts that intentionally resume the same native session;
different logical sessions can execute concurrently. Stateful repository
mutations continue to use the Space/Thread mutation coordinator, while
read-only assignments do not acquire that write lock.

Cancellation removes a queued waiter without releasing a slot it never held.
When a running assignment terminates, its slot is transferred atomically to
the next waiter. The transfer is marked reserved before the waiter resumes so
a cancellation racing with dequeue cannot launch an unwanted process.

## Recovery

Process ownership records remain durable under Application Support. Service
startup reaps only an exact Engine identity (executable, state directory and
start identity), then rebuilds capacity from the live supervisor state. A
terminal Cloud result remains idempotent by assignment and attempt identity;
transport reconnects do not re-execute an assignment.

## Compatibility

Older assignment payloads without `queueWaitTimeoutMs` or
`maxConcurrentAssignments` remain accepted during rollout. New Cloud payloads
always include both fields. The queue deadline is persisted in migration
`0055_assignment_queue_deadline.sql` so Cloud recovery does not mistake a
healthy local queue for a lost execution.
