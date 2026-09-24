# V6 Workflow runner

Runs may carry an immutable `WorkflowVersion` snapshot. When present,
`ConclaveRunWorkflow` plans one persisted `workflow_tasks` row per
`WorkflowStep`, plus dependency rows, and executes the graph in dependency
order.

Stateless independent steps can run in the same durable batch. Stateful
Workstream steps are isolated to one task at a time and retain their execution
class for Scheduler v6 routing. Human or Project-owner approval steps wait for
an approval event. A Worker result is admitted only after its output contract
is satisfied; failed steps retry up to the durable step retry limit, while
failure or cancellation propagates to dependent tasks.

The existing hardcoded lifecycle remains available for legacy Run payloads.
New v6 payloads use the product WorkflowVersion directly, so built-ins and
user-authored immutable versions share the same runner path.
