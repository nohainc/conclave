# Assignment admission correctness — separate from Phase 1

## Confirmed production fault

Before editing admission, the Cloudflare script-content API confirmed production
`conclave-ax-app` version `63aefd33-830b-4be0-8370-6a73eb64faa2` contained the
same dispatcher as the branch:

```ts
const insertion = await db.prepare(`INSERT INTO worker_assignments ... SELECT ...`).bind(...values).run();
if (Number(insertion?.meta?.changes ?? 1) !== 1) {
  // worker_concurrency_limit / capacity_claim_lost_race; never dispatches
}
```

Read-only production `sqlite_master` inspection found the insert trigger
`trg_conversation_turn_assignment_insert`:

```sql
CREATE TRIGGER trg_conversation_turn_assignment_insert
AFTER INSERT ON worker_assignments
BEGIN
  INSERT INTO conversation_turns (...)
  SELECT 'turn-' || NEW.id, ..., NEW.id, ...
  FROM workflow_tasks wt
  JOIN work_requests wr ON wr.id = wt.work_request_id
  JOIN conversation_work_requests cr ON cr.work_request_id = wr.id
  JOIN conversations c ON c.id = cr.conversation_id
  JOIN conversation_user_messages m ON m.work_request_id = wr.id
  JOIN conversation_workflow_runs wfr ON wfr.work_request_id = wr.id
  JOIN conversation_workflow_step_runs wsr
    ON wsr.task_id = wt.id AND wsr.workflow_run_id = wfr.id
  WHERE wt.id = NEW.task_id;
END;
```

That turn insert fires `trg_history_execution_created`, which inserts a
`conversation_history_entries` execution event. Other production triggers on
these tables validate identity and lifecycle; they do not reserve capacity.

## Real D1 insert evidence

A temporary remote D1 database `syntila-admission-probe-20261014` used only
synthetic rows and reproduced the two-write trigger chain. The application
continued using production D1; no production user records or schema were
modified by this probe.

| Probe | Returned IDs | D1 meta.changes | D1 rows_written |
| --- | --- | ---: | ---: |
| One assignment insert plus turn/history triggers | `diagnostic-one` | 3 | 5 |
| Insert with false capacity predicate | none | 0 | 0 |

For the first insert, SQL `changes()` was 1 and `total_changes()` was 3;
each of assignments, turns and history contained one row. `rows_written`
also accounts for index writes and must not be used as insertion proof.
This matches D1's use of SQLite total changes, including trigger writes.

The original failed request and its 3,911 ms T2→T3 evidence remain in
[PRE_FIX.md](PRE_FIX.md). That measurement belongs to failed admission.

## Correction and capacity ownership

The dispatcher now uses `INSERT … RETURNING id` and requires the returned ID
to equal the generated assignment ID. Missing or unexpected IDs still fail
admission. The check does not fall back to accepting missing result metadata.

The original INSERT has no capacity WHERE predicate or Cloud slot reservation.
It admits queued work (`allowQueue: true`). Scheduler policy eligibility and
the frozen effective capacity remain unchanged; the Service reserves the actual
local execution slot. No new capacity rule or faster execution path is added.

Regression tests use the real conversation/history SQL triggers and D1-style
total-change metadata. The old guard reproduces the rejection of a successful
insert; the new guard dispatches it. An atomic `RAISE(IGNORE)` capacity refusal
still returns no assignment and sends nothing to the gateway. Existing
scheduler and Service slot-serialization/concurrency tests cover the actual
capacity owners.

This correction is a stated precondition of any subsequent successful-path
baseline. Its commit must be recorded with the post-fix capture and must not
be mixed with pre-fix failure data. There is no migration or protocol change.

## Verification

- Focused admission, frozen selection, scheduler, and Work v1 acceptance:
  40 tests passed. Reinstating the old guard makes the positive trigger-write
  regression fail; the no-row/capacity-refusal test still passes.
- Cloud and direct TypeScript package suites: 774 passed, one existing failure
  in `model-effort-profile-corrections.test.ts` (`readdirSync` is not imported).
  That same missing import and its implicit-any fallout block Cloud typecheck;
  no additional TypeScript errors were reported for this change.
- Service Engine supervisor: 10 passed, one concurrency polling timeout on the
  first run. The isolated independent-concurrency rerun passed. Existing
  serialization, cancellation, queue timeout, and slot ownership checks passed.
- The synthetic remote probe database was removed after measurement.

This scope covers exact insertion proof with real SQL triggers, refusal without
delivery, frozen capacity propagation, and the Service's actual slot owner.
The unrelated typecheck/test failure and the concurrency timing sensitivity
remain visible limitations rather than a claim of a fully green repository.
