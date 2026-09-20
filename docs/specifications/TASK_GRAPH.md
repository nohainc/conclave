# Goal Decomposition and Task Graph

The Lead may propose Phases, Tasks, and task dependencies in `PlanResult`. Core treats that response as a proposal: it first validates unique IDs, known dependencies, self-dependencies, and cycles, then creates the graph. No worker can directly mutate graph state.

## Deterministic state machine

Task transitions are owned by `TaskGraphState`:

```text
pending -> running -> succeeded
pending -> running -> pending   (retry available)
pending -> running -> failed    (retry/budget exhausted)
pending -> blocked              (failed/cancelled dependency)
pending/running -> cancelled    (run cancellation)
failed/blocked/succeeded -> pending (explicit reopen)
```

Ready tasks are selected in the Lead’s phase/task declaration order after all dependencies succeed. A task attempt increments the run attempt counter. The policy enforces per-task attempts, total attempts, total cost, and timeout limits. Timeout is a typed failure and follows the same retry rule as another worker failure.

Cancellation is terminal for the Run and prevents new work. Reopening requires an active Run (or explicitly reactivates a failed Run) and is recorded by the caller as an event/decision. A completed Run cannot be cancelled.

`executeTaskGraph` is an execution adapter: it invokes workers for Core-approved ready tasks, reports outcomes back to the state machine, and never decides transitions itself.
