# V9 communication and execution rollout

This runbook owns Phase 9 deployment and cleanup for the
[execution acceptance contract](../acceptance/EXECUTION_RELIABILITY_V9.md).
Use the existing Cloud → Workspace Service → generic Engine path and the
existing production D1 database. No new local database or replacement Workspace
identity is part of this rollout.

## Candidate and database preparation

Record the exact Cloud, Service, Engine and Web build identifiers and admitted
Profile digests. Preserve the existing installation, runtime credential,
Workspace IDs, Work Root, registry, Profiles, Engines and sessions. Take the
normal private verified database backup before applying forward migrations.
Check migration state rather than assuming prior deployment from source files.

Prerequisites are migrations 0057 (permits), 0058 (phase timestamps), 0059
(readiness/durable queued payload), 0060 (startup milestones), and 0061
(Workflow notification retry). Apply the new conversation-turn lifecycle
repair (`0062_conversation_turn_lifecycle.sql`) after them. Its guarded data repair must be rehearsed against a backup;
do not reset the baseline or delete durable assignment/outbox records.

## Deployment sequence

1. Validate generated shared contracts and the component test results. Retain
   the baseline and fault evidence with the candidate commit/source digest.
2. Deploy migrations, then Cloud. New commands require the authenticated
   session to advertise `assignment.start_permit.v1`. A Service without it
   retains a queued assignment with `deliveryState: service_upgrade_required`;
   Cloud does not send an unfenced start. Readiness alone is insufficient.
3. Build and install the candidate headless Service and separately supervised
   Engine through the canonical build/release scripts. Drain or finish active
   work before replacing the installed executable; preserve registration and
   all local state. Starting the management app is not a prerequisite.
4. Reconnect with the same runtime identity. Confirm fresh authenticated hello,
   synchronization, inventory and readiness, including session-bound permit
   capability. Replaced sessions cannot borrow previous runtime facts.
5. Run a delivery probe, then a normal disposable test request. Confirm durable
   admission, one permit/launch, provider-start evidence, local terminal journal,
   Cloud terminal acknowledgement and Workflow convergence. A probe tests
   transport only and cannot qualify Engine/provider execution.
6. Deploy Web phase presentation and retry confirmation. Older apps can ignore
   additive fields/events; server-side retry safety remains enforced.
7. Execute the full [live acceptance matrix](../acceptance/EXECUTION_RELIABILITY_V9.md#live-release-gates)
   and collect complete idle/burst performance evidence. Approve release only
   after reviewing both fixture results and the candidate's live evidence.

Event-driven terminal notification is already the implemented normal path;
there is no new feature toggle or second completion transport. Existing
assignments from an older Service remain eligible for reconciliation and
terminal acknowledgement. New delivery requires safety capability. The Service
still understands old additive protocol shapes so a deliberate rollback can
recover existing work, but an old Cloud does not establish the new safety
guarantees and must not accept new work during such a rollback.

## Rollback and cleanup

Pause new submissions/assignment delivery first. Drain known active providers
or confirm their stop before replacing Service/Cloud builds. Keep unresolved
assignments `reconciling`; do not free capacity or mark them stopped merely to
unblock deployment. Retain local journal records and Cloud terminal notification
rows until receipt/convergence evidence exists. No automatic re-execution of an
ambiguous attempt is permitted.

Use forward repairs for database changes. Preserve migration history and the
durable Workflow step names: renaming a step key can change replay behavior
for an in-flight Workflow. Event waiting replaces routine two-second polling;
the 30-second reconciliation wake-up, phase deadlines, Service journal retry,
and cancel retry each protect a distinct recovery responsibility and remain.

Removed/superseded behavior in this audit includes unfenced new delivery to old
Services, permit retry deadline renewal, terminal notification discard when a
Workflow binding is missing, and the unused duplicate Thread-menu renderer.
Do not remove capability gates, heartbeat readiness recovery, journal tombstones
or terminal receipt handlers as obsolete timers/handlers.

## Operational diagnosis

| Observation | Inspect and act |
| --- | --- |
| Connected, but no start command | Check readiness generation/session, Worker eligibility and session permit capability. Upgrade an incompatible Service; reconnect without changing installation identity. |
| `created` with upgrade required | Nothing has been delivered. Install the compatible Service; allow the existing queue to flush or expire through its readiness deadline. |
| `dispatched`, no admission | Correlate Gateway queue and Service receipt; verify transport/session and request revocation on deadline. Do not manufacture an admission ack. |
| `acknowledged`, no provider start | Inspect queued/startup stage, slot/session gate, pinned Profile and permit timestamps. Queue and startup have separate budgets. |
| `revocation_pending` / `reconciling` | Execution ownership is uncertain. Restore the Service connection and reconcile journal/process evidence. No manual retry while stop is unconfirmed. |
| Terminal assignment, stale Workflow/Web | Inspect `workflow_signaled_at`, signal attempts, Workflow instance mapping, then authoritative Web resync. Retry notification, never execution. |
| Missing T11/T12 | Check instrumented candidate versions and raw capture continuity. Mark performance acceptance incomplete; do not substitute completion polling or infer zero duration. |
| Engine handshake fails in test process | Check the VM/DevTools preamble and strict protocol frames. Fixtures must use the same framing rules as the supervised Engine. |

There is no operator `reconciling → lost` endpoint in this release. A process
that cannot be accounted for remains unresolved until a separately reviewed
operator reconciliation mechanism has sufficient stop evidence. A product
failure message is never proof that a local process stopped.
