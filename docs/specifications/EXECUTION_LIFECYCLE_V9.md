# Authoritative execution lifecycle — V9 Phase 2

**Status:** Phase 2 implementation contract

## Authority

Cloud owns the persisted lifecycle of an assignment, attempt projection, task,
run and Work Request. Workspace owns observed local process/journal state.
The CLI Worker Engine owns provider-process observations. Activity never owns a
terminal transition.

`Recovering` is an operational condition represented by diagnostics and
reconciliation work; it is not a persisted assignment outcome. Cloud retains
the last authoritative state while it waits for Workspace sync or a deadline.

## Assignment state machine

The current database representation maps to the product states as follows:

| Product state | Cloud assignment status | Meaning |
| --- | --- | --- |
| Queued | `created` | Persisted and eligible; no delivery accepted |
| Dispatched | `dispatched` | Gateway accepted the outbound dispatch; provider has not started |
| Accepted / Starting | `acknowledged` | Workspace journal accepted the assignment; startup is still unconfirmed |
| Running | `running` | Explicit `assignment.start.ack` confirmed Engine and provider startup |
| Completed | `completed` | Durable successful terminal result |
| Failed | `failed` | Durable failure terminal result |
| Cancelled | `cancelled` | Durable cancellation outcome |
| Timed out | `timed_out` | Durable deadline outcome, with the canonical `timeout` error code |
| Lost | `lost` | Reserved final outcome for a confirmed unrecoverable execution loss |

Assignment and attempt transitions are implemented in
[`packages/core/src/execution-lifecycle.ts`](../../packages/core/src/execution-lifecycle.ts).
The current schema projects an attempt through its assignment row, but both
identities use the same fenced transition contract. Terminal states are
monotonic: no activity, acknowledgement, retry or late
terminal message can return them to `running`.

Task, Run and Work Request records retain their existing product status
vocabularies. A task becomes `running` only after startup acknowledgement. A
timed-out assignment converges its task to `failed` with a timeout error; Run
and Work Request projections are finalized by the durable Workflow after the
task result is observed.

## Message rules

1. `assignment.start` creates no running state.
2. Admission `assignment.ack` moves Cloud only through the accepted/starting
   window and never marks the task running.
3. `assignment.start.ack` is emitted only after the generic Engine and provider
   process have launched. It is correlation-checked by Workspace, runtime,
   Worker, run, task, attempt, assignment and idempotency key before Cloud
   moves the assignment and task to `running`.
4. `assignment.result`, `assignment.error` and `assignment.cancelled` are
   durable terminal deliveries. Cloud checks the attempt identity before
   applying them and ignores duplicates or stale attempts.
5. Activity and progress are accepted only while the assignment is active.
   A delayed activity event after failure or completion is ignored.
6. A terminal result received before the final activity is valid. The result
   closes the assignment; the late activity cannot reopen it.

## Durable terminal behavior

Cloud terminal writes are idempotent by `assignmentId` and `attemptId`:

- a duplicate terminal delivery for the current attempt is a no-op after the
  first terminal row is committed;
- a terminal delivery for an earlier attempt cannot modify the newer attempt;
- a terminal assignment cannot have its output, error or status rewritten by a
  later outcome;
- task finalization is conditional on the matching assignment terminal row;
- terminal delivery acknowledgement reflects the persisted Cloud result,
  including mapping Cloud `timed_out` to the compatible local failed-ack shape.

Workspace commits its local terminal journal record before attempting delivery
and retains it until Cloud acknowledgement. A reconnect sends the bounded
active/recent-terminal synchronization window. If a local non-terminal record
was interrupted by restart, Workspace reports outcome-unknown evidence; Cloud
does not infer success.

## Deadlines and recovery

| Phase | Deadline | Owner and action |
| --- | --- | --- |
| Dispatch acceptance | 30 seconds from `created`/`dispatched` update | Workflow/Cloud records retryable failure if Workspace never accepts |
| Engine/provider startup | 30 seconds from admission acknowledgement | Workflow/Cloud records retryable failure if `assignment.start.ack` is absent |
| Provider execution | Assignment/task configured timeout | Workspace stops the process tree; Cloud records `timed_out` if no terminal result arrives |
| Terminal delivery | 10 seconds per local send attempt | Workspace keeps the journal terminal record and retries after reconnect |
| Disconnected runtime reconciliation | 30 seconds after the latest assignment/runtime evidence | Cloud leaves recovery evidence, gives sync a chance, then classifies the assignment as provider-unavailable failure if no terminal evidence exists |

The configured assignment timeout remains the execution deadline; dispatch and
startup windows do not prove provider execution and do not consume the provider
result authority. Cloud recovery is safe to run repeatedly because terminal
transitions are idempotent.

## Process disappearance without provider terminal output

If the Engine process exits without a mapped provider result or error, the
Workspace supervisor cleans the process tree and emits a normalized failure.
The local journal stores the failure before transport delivery. The failure
includes only bounded safe diagnostic evidence such as a process exit code or
`missing_terminal_event`; provider output and credentials never cross the
boundary. If Workspace itself restarts before that evidence is written, the
assignment is outcome-unknown during reconciliation and Cloud eventually
records a retryable provider-unavailable/lost outcome after the reconciliation
deadline.

## Acceptance matrix

| Scenario | Required result |
| --- | --- |
| Duplicate completion | One completed assignment; later delivery is a no-op |
| Failure followed by delayed progress | Failure remains final; delayed progress is ignored |
| Result before last activity | Result remains authoritative; activity may be dropped |
| Service reconnect with unfinished assignment | Sync reconciles the journal; no success is guessed |
| Process exit without provider terminal | Durable normalized failure or outcome-unknown recovery, never indefinite running |
| Cloud receives stale previous-attempt event | Identity check rejects it; current attempt is unchanged |

