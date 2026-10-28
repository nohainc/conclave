# Command delivery and safe revocation — V9 Phase 3

**Status:** Phase 3 implementation contract. Slice A (Cloud revocation
lifecycle), Slice B (start permit fencing and durable cancel tombstones) and
Slice C (separate deadlines) are implemented.

## Problem

Cloud used to turn a missed deadline into a terminal `failed`/`timed_out`
row. That row said "stopped" while the `assignment.start` command could still
sit in the Service queue or the provider could still be running, so a
`syntila-agent` process appeared after the Run had already failed. A deadline
entitles Cloud to want the work stopped; only the Service can say it stopped.

## Delivery is not execution

The command path, using only the existing authenticated Workspace transport:

1. Cloud persists the assignment (`created`) and its identity
   (`assignmentId`, `attemptId`, `idempotencyKey`, `workspaceRuntimeId`).
2. The Gateway persists `dispatched` **before** it writes the command, then
   writes it to the WebSocket or long-poll queue. From this moment Cloud must
   assume the Service may hold the command.
3. The Gateway answers `delivered: true, deliveryState: "queued",
   acceptance: "pending"`. That means *queued for delivery*, never *received*.
4. The Service durably records the command, then answers `assignment.ack`
   (`accepted: true` = admission, `accepted: false` = explicit rejection).
5. Queueing, Profile download, readiness and CLI startup happen after the
   acknowledgement and never delay it.
6. The Service reports provider start (`assignment.start.ack`) and the
   terminal outcome independently.

If the Gateway cannot write the command, it knows first-hand that none exists
and fails the assignment directly. If the dispatch call fails in any other way
(for example the response is lost), the outcome is ambiguous and the failure
goes through revocation.

## Revocation lifecycle

| Status | Meaning | Holds capacity | Public projection |
| --- | --- | --- | --- |
| `revocation_pending` | Cloud decided the work must not run; `assignment.cancel` is outstanding | yes | still running/stopping |
| `reconciling` | No confirmation after 20 s; the process may be alive. The cancel keeps being re-sent | yes | still running, flagged unresolved |

```
dispatched | acknowledged | running --> revocation_pending --> terminal
                                              |                  ^
                                              +--> reconciling --+
```

Rules (all enforced by the conditional-UPDATE contract in
`packages/core/src/execution-lifecycle.ts`):

- Only `dispatched`, `acknowledged` and `running` can be revoked. A `created`
  assignment was never handed to the Gateway, so it is finalized immediately.
- Admission and provider-start evidence can never move a revoking assignment
  back to `acknowledged` or `running`.
- The intended terminal outcome (`cancelled`, `timed_out` or `failed`, with
  its error) is stored in `error_json.revocation` together with a stable
  `commandId` (`revoke:<assignmentId>:<attemptId>`). The first intent wins.
- The intent is written as the terminal status only on Service evidence:
  `assignment.cancel.ack` with `cancelled: true`, `assignment.cancelled`, or a
  Service-reported result/error. A result that beats the stop is accepted as
  `completed`: the provider finished before it could be stopped.
- If no evidence arrives, the assignment stays visible and unresolved. Cloud
  never reports a conclusively stopped process it has not confirmed.
- Recovery decisions carry the status they were made from; if the assignment
  has since progressed, the stale decision is dropped.

### What starts a revocation

| Trigger | Source | Intended outcome |
| --- | --- | --- |
| Workflow delivery/admission/startup deadline | `startup_deadline` | `failed` (retryable `provider_unavailable`) |
| Workflow or recovery execution deadline | `execution_deadline` | `timed_out` |
| Workspace offline > 30 s | `workspace_disconnected` | `failed` |
| Workspace lease (grant) expired | `grant_expired` | `failed` |
| Work Request cancelled / user cancel | `work_cancelled`, `manual_cancel` | `cancelled` |
| Dispatch call failed after delivery was persisted | `dispatch_failed` | `failed` |

### How the cancel reaches the Service

- Immediately, through the Gateway's existing `/cancel-assignment` path.
- On every `workspace.sync.request` (reconnect, restart): the Gateway re-sends
  `assignment.cancel` for each unconfirmed revocation of that Workspace, with
  the same `commandId`.
- On every recovery pass (cron) and while the Workflow waits.

A redispatch of a revoking assignment is refused (`shouldSend: false`), so a
retry or replay cannot become a start command.

## Retry safety

A Workflow step is replayed as a new attempt only when the previous attempt
provably did nothing. `classifyStepAssignmentOutcome` fails the step without
retry when the stop is unconfirmed (`revocation_pending`/`reconciling`) or when
Cloud stopped an assignment the provider had already started. A confirmed stop
of work that never started, and failures the Service reported itself, keep
their previous retry behavior.

## Recovery limits and Phase 9 corrections

- A Workspace that never returns leaves its revoked assignments `reconciling`
  and holding capacity. An explicit operator reconciliation action (to a
  terminal `lost`) is not part of this phase.
- Grant revocation (`routes/workspaces-grants.ts`) now uses canonical revocation
  for every active assignment. Only never-delivered work can be finalized
  immediately; outstanding execution retains ownership. Recovery handles a
  crash between revoking the grant and requesting assignment cancellation, and
  permit issuance rechecks the grant in the same conditional write.
- Forward migration `0062_conversation_turn_lifecycle.sql` replaces the old
  conversation-turn trigger: admission remains queued, provider-start evidence
  marks running, and `timed_out`/`lost` project to failed. Its narrow repair
  preserves terminal history and ambiguous historical start timestamps.

## Slice B: Service start fencing

**Capability.** The Service advertises `assignment.start_permit.v1` in the
hello `capabilities.customCapabilities`. Cloud reads it from the runtime facts.
Protocol version stays 5.1; the messages are additive and capability-gated.
Phase 9 requires this capability from the current authenticated session before
any new delivery. An older Service receives no new start command; existing
assignments can still reconcile and deliver terminal outcomes. Historical
unfenced rows retain the confirmation-wait behavior during recovery.

**Dispatch.** For a capable Service Cloud sets
`worker_assignments.start_permit_required = 1` before writing the command and
adds `snapshot.startPermit = {required: true}` to `assignment.start`.

**Permit.** After the slot is reserved and immediately before the Engine
process is created the Service sends `assignment.start.permit.request` over the
existing Gateway socket (re-sent every 3 s, 15 s limit). The Gateway answers
`assignment.start.permit.grant`:

- `granted: true` with `permitId` and a 30 s `expiresAt` only through the
  conditional `UPDATE ... WHERE status='acknowledged' AND attempt_id=?
  RETURNING id`, which stamps `start_permit_issued_at` once. A repeat request while
  the assignment is still `acknowledged` receives the same permit/expiry, never
  a renewed startup window. The conditional write also fences Workspace/runtime
  identity and active grant status. A request that
  overtakes `assignment.ack` advances `dispatched -> acknowledged`.
- `granted: false` with a reason (`revoked`, `terminal`, `already_started`,
  `stale`, `not_found`) otherwise.

The Service fails closed: a denial, a timeout, a grant for another attempt, or
a lost connection means no process is started and the assignment ends
`cancelled` locally.

**Fencing in Cloud.** The permit grant and the revocation transition race on
the same row, so exactly one wins. If revocation wins and no permit was ever
issued (and the observed status is not `running`), the Service cannot launch,
so Cloud finalizes immediately without waiting for Service confirmation
(*fenced*) and sends a best-effort cancel. If a permit was issued, the process
may exist, so revocation waits for Service evidence (`reconciling` on
timeout) and the workflow classifies the outcome as revoked-while-running,
which is never auto-retried.

**Durable cancel tombstones.** A cancel for an assignment the Service has not
admitted is appended to the assignment journal as `cancelled`, with the full
correlation (attempt, runtime, idempotency key). A later or replayed
`assignment.start` finds the record and answers `assignment.cancel.ack`
instead of launching, across Service restarts. Because the record is a
terminal journal entry, the existing journal-driven terminal retry re-sends
`assignment.cancelled` after reconnect until Cloud acknowledges it; this also
covers terminal results and errors, which were already journaled before
delivery. Cancels for assignments already in the active set are not
journaled early, so a late success can never be overwritten.

## Slice C: separate deadlines

Every deadline starts at its own event. Migration `0058` adds
`dispatched_at`, `acknowledged_at` and `running_at` to `worker_assignments`;
they are stamped first-write-wins (`COALESCE`) by the transition writers, so a
replay can never push a deadline back. `start_permit_issued_at` (0057) is the
startup event. Rows that predate the migration fall back to `updated_at` /
`created_at`. The rule lives in one pure function,
`currentAssignmentDeadline` / `assignmentDeadlineViolation`
(`assignment-delivery.ts`), used by both the Workflow and stale recovery.

| Deadline | Starts at | Ends at | Limit | Owner |
| --- | --- | --- | --- | --- |
| Command delivery | Gateway queues the command (`dispatched_at`; `created_at` only for a never-queued assignment) | Service admission ack | 30 s | Cloud |
| Admission | Service receives and validates the command | Same ack | (shared with delivery) | Service |
| Queue wait | Service accepts it into its queue (`acknowledged_at`) | Start permit granted | `queueWaitTimeoutMs` | Cloud |
| Startup | Start permit granted (`start_permit_issued_at`) | Provider start evidence | 30 s | Cloud |
| Provider execution | Provider starts (`running_at`) | Terminal outcome | assignment `timeoutMs` | Service and Cloud |
| Terminal delivery | Outcome durably recorded in the journal | Cloud acknowledges receipt | 10 s per attempt, retried | Service |

Notes:

- Service receipt and admission share one acknowledgement message, so Cloud
  observes them as a single deadline. The Service's own contract is that the
  ack never waits for Profile downloads, readiness probes, repo init or CLI
  startup; those run after admission.
- A Service without start permits cannot signal when a slot became available,
  so for it queue wait and startup remain one window from admission, as
  before.
- Terminal delivery has no Cloud-side timer. The Service keeps the terminal
  record in its journal and retries after reconnect until Cloud acknowledges.
- A violated deadline never marks the assignment stopped. It starts
  revocation (see above); the outcome is written on Service evidence, or
  immediately when the start permit fencing proves nothing could have run.
- Behavior changes from Phase 2: queue wait is no longer measured from
  assignment creation by recovery, and provider execution is measured from
  `running_at` instead of the last row update.

## Acceptance matrix (Slice A)

| Scenario | Required result |
| --- | --- |
| Queued assignment times out | `revocation_pending`; cancel sent; no terminal row until confirmed |
| Late admission/start acknowledgement after revocation | Ignored; status unchanged |
| Redispatch of a revoking assignment | Refused; no `assignment.start` queued |
| Service offline during revocation | Stays `revocation_pending`, then `reconciling`; re-sent on sync |
| Service confirms the cancel | Intended outcome written; task projection follows |
| Result arrives before the stop | `completed` |
| Timeout of a started assignment | Stop confirmed, step not replayed |
| Stale recovery decision | Dropped when the assignment has progressed |
| Dispatch response lost after delivery persisted | Revocation, not a bare failure |
