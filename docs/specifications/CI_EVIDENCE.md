# CI/CD Evidence

Conclave treats model statements and machine observations as different evidence classes. A reviewer saying “tests pass” is a claim. A `MachineCheckEvidence` record is accepted evidence only when it identifies the source, external run, exact revision, workflow, conclusion, individual checks, and observation time.

## Evidence contract

Each machine evidence record contains:

- `source`: `github_actions`, `local_runtime`, or another CI source;
- external run ID, workflow name, repository revision, and observation time;
- overall conclusion plus one or more named checks;
- each check's status, command, exit code, and artifact references;
- optional coverage percentage, preview URL, smoke tests, and health checks.

The `MachineCheckEvidenceSchema` is runtime-validated. Empty check lists and malformed conclusions cannot enter the workflow. A successful overall conclusion is not enough by itself: the final report retains the individual check list.

## GitHub Actions integration

The repository workflow continues to run TypeScript, Worker startup, Flutter analysis, and Flutter tests. When the repository variables `CONCLAVE_CI_INGEST_URL` and `CONCLAVE_RUN_ID` are configured, the `publish-evidence` job posts a normalized success record to:

```text
POST /api/runs/:runId/ci-evidence
Authorization: Bearer <CONCLAVE_CI_INGEST_TOKEN>
```

The token is a GitHub Actions secret and is never committed. The Worker optionally enforces it when `CONCLAVE_CI_INGEST_TOKEN` is configured as a Worker secret. The job is skipped when no Conclave run is attached, so ordinary repository CI remains independent.

## Durable run behavior

A durable run waits for a `ci-evidence` Workflow event after implementation and before final verification unless `requireCiEvidence` is explicitly disabled for a controlled non-production run. The validated evidence is included in the durable completion checkpoint, so a status read after a Worker restart still exposes the exact machine checks that were observed.
