# Post-fix partial latency baseline — 2026-10-14

## Preconditions and outcome

Correctness commit: `17e611fd` (assignment admission by returned identity).
Production Cloud version: `7c677fa1-63ee-45d0-bc5a-eab6e1208a97`.
Telemetry capture fixes were committed separately as `87e38bb0`; Slice C is
`e542e191`. No performance-path change was included.

24 short Chat requests completed: six sequential idle requests and 18 burst
submissions, all using the existing Claude Worker, production D1, and the
instrumented headless Service running from source on this Mac. Workspace.app
was not needed to own or start this runtime. Prompts requested only an OK
response, with no tools or file changes. Two requests used production Web,
22 used the authenticated normal API. The temporary API session was revoked.

This is a **partial baseline, not the completed Phase 1 gate**. T5–T10 are
present for all 24 requests, T2 for 23, T3 for 24, T4 for six, and T11 for none.
Production Web assets predate the recorder, so T1/T12 are absent.
Missing T11 is an unresolved capture/instrumentation issue: API completion and
Workflow terminal-observation events are not substituted for durable terminal
timestamps. The first T2 and some gateway events were not observed by the tail.
Do not interpret absent events as zero duration.

The pre-fix failed admission and its 3,911 ms T2→T3 remain separately preserved in
[PRE_FIX.md](PRE_FIX.md). They are excluded from this successful-path dataset.

## Measured intervals

| Interval | n | p50 ms | p95 ms | max ms |
| --- | ---: | ---: | ---: | ---: |
| T2→T3 Cloud acceptance to Workflow dispatch | 23 | 3605 | 7170 | 20718 |
| T3→T4 Workflow dispatch to Gateway queue | 6 | 835 | 2357 | 2357 |
| T4→T5 Gateway queue to Service receipt | 6 | 155 | 210 | 210 |
| T3→T5 (T4 missing; combined interval) | 18 | 1218 | 1346 | 1346 |
| T5→T6 Service admission | 24 | 113 | 124 | 140 |
| T6→T7 Profile resolution | 24 | 20 | 22 | 24 |
| T7→T8 Slot reservation | 24 | 4 | 888 | 1286 |
| T8→T9 Engine process creation | 24 | 24 | 44 | 48 |
| T9→T10 Provider-start boundary | 24 | 43 | 49 | 51 |

The largest **observed** interval is before delivery for 23 of 24 traces.
This identifies where to investigate next; it does not establish an internal
Workflow cause or compare delivery against the unmeasured T10→T11 interval.
A burst submission is not proof every request queued; Service traces show
active-assignment overlap and slot waits, not a sustained saturation workload.
With only 24 samples, tail percentiles are exploratory rather than stable SLOs.

Four delivery probes were acknowledged over HTTP long-poll: 225 ms, 230 ms,
799 ms (activeAssignments=1), and 666 ms (idle). Clock estimates carried by
traces were applied; the report found no uncorrected Service clocks and no
negative intervals. Cross-host accuracy remains bounded by the measured RTT,
not by the number of decimal places printed.

## Reproduction and evidence

```bash
node scripts/latency-baseline.mjs \
  --cloud docs/acceptance/latency/2026-10-14/post-fix-cloud.jsonl \
  --service docs/acceptance/latency/2026-10-14/post-fix-service.jsonl \
  --json /tmp/conclave-post-fix-baseline.json
```

- [Request IDs, labels and completed statuses](post-fix-requests.json)
- [Cloud trace-only capture](post-fix-cloud.jsonl)
- [Service trace-only capture, including log rotations](post-fix-service.jsonl)
- [Machine-readable statistics](post-fix-baseline.json)
- [Admission diagnosis and regression verification](ADMISSION_CORRECTNESS.md)

Raw logs remain outside Git in /private/tmp and the existing Service log
directory. Committed captures contain schema diagnostic trace events only;
no authentication tokens, prompts, or provider output.

## Verification and remaining work

The report was reproduced from the committed captures: 24 joined traces.
Focused report-parser and admission regression suites: seven tests passed.
Earlier correctness verification and the unrelated existing Cloud suite/typecheck
failure are recorded in ADMISSION_CORRECTNESS.md. This scope checks the changed
insert behavior and report parsing without building unrelated applications.
No database migration, protocol change, or rebuilt Engine artifact is included.

Before declaring the gate complete, diagnose missing T11 events without changing
execution behavior, collect a complete T2–T11 capture, and add instrumented Web
T1/T12 when available. Keep this partial dataset and the failure-path evidence;
do not silently merge captures with different behavior or deployment versions.
