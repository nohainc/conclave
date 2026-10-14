# Workflow terminal events V9 (Phase 6)

Goal: wake the Cloud Workflow as soon as an assignment is terminal, instead of
reading D1 every two seconds. D1 remains the only authority for the outcome.

## Sequence

1. Service reports `assignment.result` / `error` / `cancelled`.
2. Cloud persists the terminal status in D1 (existing guarded writers).
3. Cloud sends `assignment.ack` to the Service.
4. Cloud sends the `assignment-terminal` event to the run's Workflow instance
   (`signalAssignmentTerminal`) and stamps `worker_assignments.workflow_signaled_at`.
5. The Workflow wakes, re-reads the assignment from D1 and classifies the
   outcome with the existing `classifyStepAssignmentOutcome`.
6. Existing publication to the Web app is unchanged.

Signalling is never a precondition for step 3, and a failure in step 4 cannot
change the outcome or the acknowledgement.

## Identity and mapping

`worker_assignments(run_id, task_id, attempt_id)` joined to
`runs.workflow_instance_id` is the instance/task/assignment/attempt mapping.
The event payload carries `assignmentId`, `attemptId`, `taskId`, `runId` and
`status`. It is a hint only: the Workflow never trusts it, it re-reads D1.

The event type is `assignment-terminal` (Workflows event types cannot contain
dots).

## Outbox and recovery

Migration 0061 adds `workflow_signaled_at` and `workflow_signal_attempts`.
A terminal row with `workflow_signaled_at IS NULL` _is_ the outbox; there is no
second write path.

- Immediate: the Gateway signals after the terminal acknowledgement.
- Sweep: the `*/5` cron retries unsignalled terminal rows (last 24 h, fewer
  than 5 attempts, 50 per run).
- Waiter: every wait ends by itself after at most 30 s, so a lost event costs
  at most one reconciliation interval regardless of the sweep.
- A run without a Workflow instance is stamped as handled.

## Workflow waiting

For each Work Step the Workflow dispatches, then loops:

1. read the assignment from D1 (and nudge queued work, as before);
2. if terminal, continue;
3. apply the existing phase-deadline revocation;
4. `step.waitForEvent("...assignment-wait:<attempt>:<n>", { type:
"assignment-terminal", timeout })` where `timeout` is the time left in the
   current phase, capped at 30 s and floored at 1 s.

Properties:

- _Event before the wait_: Workflows buffers it, so the wait returns at once;
  and the read in step 1 sees the terminal row anyway.
- _Duplicate or stale events_ (another attempt, another task, a replay): they
  only cause an extra wake-up and one D1 read. Waits have deterministic names
  per attempt and wake-up, so a duplicate cannot repeat a step.
- _Lost event_: the wait times out (caught, not an error) and the next read
  finds the durable state.
- _Provider overrun_: a running assignment is treated as timed out when it is
  past `timeoutMs` plus a two-minute grace, measured from `running_at`. The
  grace lets the Service report its own timeout first.
- Revocation confirmation: three 10 s wait rounds (previously fifteen 2 s
  polls) re-sending the cancel between rounds, then one final read.

The normal path (event arrives) performs no periodic D1 reads. Remaining
periodic reads are the 30 s reconciliation and the phase-deadline wake-ups.

## Behavior changes

- Startup deadlines (command delivery 30 s, startup 30 s, queue wait) are
  still enforced, but detection is now at wake-up granularity: exact for the
  phase being waited on, up to 30 s late when a phase change shortens the
  deadline mid-wait.
- Queued (`created`) assignments are nudged on each wake-up (≤30 s) instead of
  every 2 s; the Gateway's own flush on readiness is the primary path.
- A Workflow step count per Work Step drops from hundreds to a handful.

## Dispatch and Workflow-creation latency review (task 12)

Not changed in this phase; findings for follow-up, measurable with the
existing T2→T3 interval (`cloud_accepted` → `workflow_dispatch_started`):

- Before the dispatch step, `runVersioned` performs sequential, un-checkpointed
  work: prompt-input load, request-mode read, a status batch, task persistence,
  the `work_request.started` event, `step.queued` events and the queued task
  state write. Several are independent and could run concurrently; ordering of
  `started` before `step.queued` must be preserved.
- The dispatch step is itself a durable step; its own cost is the dispatcher
  (target selection, assignment insert, Gateway call).
- Workflow instance creation (`create`) is asynchronous; the instance start
  delay is outside Cloud's control and shows up as T2→T3.

## Deploy

Migration 0061, then Cloud. The Service is unchanged.
