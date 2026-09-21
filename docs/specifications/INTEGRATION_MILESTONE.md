# Conclave AX Integration & Production-Readiness Milestone

This milestone closes the gap between individually tested components and a real end-to-end Conclave AX system.

## I1 — Persistence completeness

Implement D1 repositories for every Core entity used by Forge: projects, workers, goals, completion criteria, runs, phases, tasks, dependencies, attempts, model calls, findings, verifications, artifacts, events, usage, organizations, memberships, budgets, credentials, extensions, workflow templates, and approvals as required by active flows.

Use R2 for large artifacts and add a size threshold so model/provider/runtime payloads do not grow D1 indefinitely.

**Exit:** a real Forge run persists and reconstructs from D1/R2 after process restart.

## I2 — Tenant-safe read model

Replace global Studio queries with a tenant/run-scoped read model.

All workers, tasks, findings, events, artifacts, model calls, and active-run selection must be filtered through authorized projects/runs for the current organization. Project selection must reload the corresponding aggregate.

**Exit:** two organizations seeded in the same D1 database cannot observe each other's data.

## I3 — Run identity and durable lifecycle

Define the distinction between:
- Conclave domain `run.id`;
- Cloudflare Workflow instance id;
- external CI run id.

Persist the Workflow instance id explicitly. All pause/resume/restart/status/event APIs must resolve the domain run to its Workflow instance.

The durable workflow must not mark execution completed merely because Forge execution was dispatched. It must await an explicit Forge terminal result/event and persist terminal state.

**Exit:** a run survives restart, resumes correctly, and terminal status matches Forge's real terminal result.

## I4 — Real Forge execution service

Implement the `CONCLAVE_FORGE_EXECUTION` service using real:
- D1/R2 persistence adapters;
- Worker Registry;
- configured provider adapters;
- artifact/context resolver;
- Local Runtime transport;
- Forge orchestration.

It must return/emit a durable execution id and terminal result.

**Exit:** no mock/in-memory implementation participates in the production execution path.

## I5 — Local Runtime transport

Implement the real outbound Studio/Runtime <-> Cloud transport with authentication, reconnect, request acknowledgement, cancellation, operation expiry, and audit correlation.

Bind approvals to organization, project, run, task, repository, allowed operation kinds, and expiration.

Add bounded stdout/stderr capture and process-tree cancellation.

**Exit:** Cloud requests a safe operation from a local repository without inbound ports and receives evidence correlated to the correct task.

## I6 — Production authentication

Replace the single configured bearer token with a production identity mechanism. Prefer Cloudflare-native protection for early private deployments or implement a real user/session identity provider.

Never put long-lived API bearer secrets in Flutter web assets.

Keep CI ingestion separately authenticated.

**Exit:** browser users authenticate without embedded secrets; unauthorized/other-tenant requests fail closed.

## I7 — Studio functional completion

Replace remaining static text/metrics with live run data. Implement:
- project selection reload;
- goal creation;
- run start;
- pause/resume/cancel;
- retry task where supported;
- live/polled refresh;
- actual phases/tasks;
- criteria and evidence;
- worker/model call costs;
- empty states.

**Exit:** Studio can create, observe, and control a real run.

## I8 — Real CI evidence loop

Create per-run CI correlation and authenticated evidence ingestion. The durable run should request/await only evidence matching the expected repository revision and workflow.

Reject stale, wrong-revision, duplicated, or cross-run evidence.

**Exit:** GitHub Actions evidence is linked to exactly one expected run/revision and influences completion policy.

## I9 — End-to-end acceptance repository

Create a tiny disposable fixture repository with a known bug and failing regression test scenario.

Run Conclave AX using at least two real independent AI workers:
1. research;
2. plan;
3. implement real file changes;
4. independent review;
5. correction if needed;
6. real tests;
7. completion-criteria verification;
8. persistence reconstruction;
9. Studio display.

**Exit:** the complete vertical slice succeeds from user goal to verified repository state without manual message copying.

## I10 — Production hardening

Add structured telemetry, redaction, rate limits, budget enforcement, retention jobs, migration verification, backup/export strategy, dependency/security scanning, and a deployment rollback procedure.

**Exit:** production checklist passes before enabling public beta.
