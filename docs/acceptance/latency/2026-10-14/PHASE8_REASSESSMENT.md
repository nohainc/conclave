# Historical baseline reassessment for Phase 8

This is a fresh analysis of the **existing** 2026-10-14 capture, not a new
candidate run or evidence of a speed improvement. Build: `17e611fd`; Cloud
deployment: `7c677fa1-63ee-45d0-bc5a-eab6e1208a97`. Request cohorts come from
[the retained labels](post-fix-requests.json): six idle and 18 burst requests.
The original [partial baseline](POST_FIX_BASELINE.md) and pre-fix failure remain
unchanged.

The new acceptance evaluator returns **incomplete**. T11 and Web T1/T12 are
absent, the historical transport is HTTPS fallback, the idle sample count is
below ten, and process-epoch/cache evidence required for candidate acceptance
was not captured. “Burst” describes submission labels, not proof of sustained
moderate load. These samples cannot certify the healthy-WebSocket targets.

## Observed intervals, separated by cohort

All values are milliseconds, nearest-rank percentiles. Missing observations
are not zero. Historical Service timestamps use the per-event offset as in the
original baseline; these exploratory figures do not satisfy the new strict
monotonic-process evidence gate.

| Interval | Idle n | Idle p50 | Idle p95 | Burst n | Burst p50 | Burst p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| T2 → T3 Cloud accepted to dispatch | 5 | 3952 | 20718 | 18 | 3516 | 4655 |
| T3 → T4 Dispatch to Gateway queue | 4 | 815 | 2357 | 2 | 1016 | 1130 |
| T4 → T5 Gateway queue to Service receipt | 4 | 155 | 165 | 2 | 142 | 210 |
| T3 → T5 Combined where T4 is missing | 2 | 1091 | 1156 | 16 | 1229 | 1346 |
| T5 → T6 Service admission | 6 | 112 | 115 | 18 | 113 | 140 |
| T6 → T7 Profile resolution | 6 | 20 | 24 | 18 | 20 | 22 |
| T7 → T8 Slot reservation | 6 | 3 | 4 | 18 | 4 | 1286 |
| T8 → T9 Engine process creation | 6 | 23 | 24 | 18 | 24 | 48 |
| T9 → T10 Provider-start boundary | 6 | 39 | 43 | 18 | 45 | 51 |
| T10 → T11 Provider to durable terminal | 0 | — | — | 0 | — | — |
| T11 → T12 Web delivery | 0 | — | — | 0 | — | — |

The largest measured cost is Cloud acceptance to dispatch, followed by the
burst queue/slot interval and dispatch-to-Gateway work. This ranks measured
investigation candidates; missing terminal data prevents ranking the complete
request lifecycle. Service admission is measured separately and does not
support assuming it is the dominant cost. No causal claim about Workflow
internals or performance improvement follows from this table.

## Reproduction

Import `eventsFromText`/`buildTraces`/`report` from
`scripts/latency-baseline.mjs`, join the two retained JSONL files, and partition
traces by the request IDs in `post-fix-requests.json` before reporting. The
strict `execution-latency-acceptance.mjs` evaluator reports these same observed
interval tables when given a manifest with those cohort labels, while refusing
to certify the historical evidence. Do not invent `ready`, `cachedProfile`,
process epochs or missing terminal events to make the manifest pass.
