# Conclave Development Roadmap

This roadmap is ordered for AI delegation. Do not skip foundational phases merely to reach UI or provider integration faster.

## Phase 0 — Product and domain specification
Define goals, workers, roles, tasks, attempts, artifacts, findings, verification, decisions, events, completion criteria, and the Forge MVP workflow.

See [docs/specifications/DOMAIN_SPECIFICATION.md](docs/specifications/DOMAIN_SPECIFICATION.md) for the normative domain model, lifecycle, failure semantics, and Forge workflow.

**Exit:** the full lifecycle from user message to verified completion is unambiguous, including ownership of state transitions, required evidence, independent review, correction loops, and terminal failure states.

## Phase 1 — Monorepo and quality foundation
Create TypeScript/pnpm workspace, Flutter client, Cloudflare Workers app, local runtime package, formatting/linting/tests, GitHub Actions, local development documentation.

**Exit:** Flutter, TypeScript, Worker, and local-runtime smoke tests pass in CI.

## Phase 2 — Conclave Protocol
Implement versioned structured contracts for task, plan, research, implementation, review, test, verification, decision, and completion messages. Validate all external/AI input.

See [docs/specifications/PROTOCOL.md](docs/specifications/PROTOCOL.md) for the envelope, contract inventory, and Core admission rule.

**Exit:** malformed responses cannot enter Core state; they are rejected for retry or rerouting, and runtime contract tests pass.

## Phase 3 — Persistence and event model
Create D1 schema/migrations and repository interfaces for projects, workers, goals, runs, phases, tasks, attempts, model calls, findings, verifications, artifacts, events, and usage. Configure R2 artifact references.

**Exit:** a run can be reconstructed from persisted state and ordered events.

## Phase 4 — Worker registry and provider abstraction
Create worker/capability/role/permission configuration. Add exactly two initial model adapters and mock workers.

**Exit:** Core routes a typed task to a capability-compatible worker without provider-specific domain logic.

## Phase 5 — Minimal two-model orchestration
User goal -> Lead -> specialist -> Lead evaluation -> completion. Persist every transition and call.

**Exit:** first real multi-model goal completes through Conclave.

## Phase 6 — Goal decomposition and task graph
Add phases, tasks, dependencies, retries, budgets, cancellation, and deterministic state transitions. AI proposes plans; Core validates/persists them.

**Exit:** a larger goal executes as multiple dependent small tasks.

## Phase 7 — Independent verification loops
Add findings, review decisions, reopen/fix/re-review loops, verification policies, and isolated reviewer contexts.

**Exit:** an implementation cannot complete while blocking findings or required verification remain unresolved.

## Phase 8 — Conclave Studio execution UI
Build project/goal creation, worker setup, goal graph, timeline/events, task details, findings, artifacts, and conversational goal interface.

**Exit:** a user can observe and control a cloud run from Studio.

## Phase 9 — Conclave Local Runtime
Implement secure outbound connection, repository registration, file/search operations, Git status/diff, controlled shell/test/build execution, permissions, and audit events.

**Exit:** Cloud can request an allowed local operation and receive verifiable evidence without exposing an inbound local port.

## Phase 10 — Conclave Forge MVP
Implement the software-development workflow: repository research -> plan -> implementation -> review -> fix loop -> tests -> final verification -> completion report.

**Exit:** Conclave can take a real repository and development goal and complete it using at least two independent AI workers plus real tests.

## Phase 11 — Durable cloud execution
Map long-running goal execution to Cloudflare Workflows. Add cancellation/resume/recovery/idempotency. Introduce Queues or Durable Objects only for demonstrated needs.

**Exit:** runs survive Worker restarts and long waits without losing state.

## Phase 12 — CI/CD and evidence
Integrate lint/build/unit/integration checks, optional preview deployments, smoke tests, approvals, and post-deploy verification.

**Exit:** completion reports distinguish AI assertions from machine-generated evidence.

## Phase 13 — Security, tenancy, quotas, observability
Organizations, RBAC, BYOK encryption, usage/cost accounting, rate limits, audit logs, telemetry, retention policies, threat model.

## Phase 14 — Extensibility
Plugin/SDK contracts, additional providers and agents, headless Runner, reusable workflow templates, optional visual workflow builder.

## Non-goals before Forge MVP
- many AI providers;
- marketplace;
- vector-memory subsystem without a proven need;
- mobile apps;
- generic no-code workflow builder;
- premature microservices.
