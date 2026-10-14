# Pre-fix, failed admission

This is failure-path evidence, not a successful-execution baseline. The Phase 1
gate remains open. Do not combine it with post-correctness-fix measurements.

- Captured 2026-10-14 against production `https://app.conclaveax.com` and D1
  `conclave-v8-production`; no local database or migrations.
- Cloud version: `63aefd33-830b-4be0-8370-6a73eb64faa2`, based on `e542e191`
  plus the telemetry clock fix committed with this report.
- Service: branch source running headlessly with the existing registration;
  authenticated IPC confirmed WebSocket, synchronized, and accepting work.
- Request: `work-request-c7a59d81-08bb-4fa8-940e-aba06cfb457d`.
- T2: `2026-10-14T13:14:43.478Z`.
- First T3: `2026-10-14T13:14:47.389Z`.
- T2→T3: **3,911 ms**, one failed-admission request. This is not normal
  execution latency or a representative percentile.
- Four dispatch attempts reported `worker_concurrency_limit` with
  `capacity_claim_lost_race`; no T4 or Service T5–T10 was observed.
- Web T1/T12 and delivery probes were not captured.

The adjacent JSONL preserves the original privacy-safe diagnostic events from
Wrangler, including IDs, timestamps, dispatch retries and admission failures.
Raw HTTP logs are excluded because they contain unrelated request metadata.

Reproduce the partial report from the repository root:

```sh
node scripts/latency-baseline.mjs --cloud docs/acceptance/latency/2026-10-14/pre-fix-failed-admission.jsonl
```

The telemetry-only capture fixes omit Cloud clock readings that exceed the
bounded optional field, parse Wrangler's `details.event` wrappers and multiline
JSON, and recognize the Service component name for clock correction. They
do not change assignment admission or execution.
