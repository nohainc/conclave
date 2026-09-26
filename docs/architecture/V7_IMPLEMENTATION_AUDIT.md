# Architecture v7 Implementation Audit

**Reviewed baseline:** `02ce1db`
**Audit date:** 2026-09-26
**Architecture:** [Architecture v7](ARCHITECTURE_V7.md)
**Release gates:** [V7 completion plan](../roadmaps/ARCHITECTURE_V7_COMPLETION.md)

## Executive assessment

Architecture v7 is the **current and sole Worker ownership architecture**. It
is **not yet the implemented baseline**. The Phase 1–3 architecture work and
Phase 4 public-key release trust are implemented. Production Worker acceptance,
full failure/security acceptance, and native macOS app update recovery remain
open. Do not change the baseline declaration until every release gate has
executable evidence.

## Current product boundaries

### Conclave AX

The web application owns human authentication, Projects, Workstreams, Discuss,
Work, Workspace grants, remote Worker inventory and Cloud scheduling controls,
results, artifacts, and audit. It does not create local Worker credentials.

### Conclave Cloud

Cloud owns collaboration and scheduling state, Workspace registration/grants,
safe inventory projections, Project/Workstream execution policy, assignments,
and the Workspace Gateway. Cloud never receives provider credentials and does
not make local Worker readiness or permissions broader.

### Conclave Workspace

Workspace is the persistent desktop runtime and machine security boundary. It
owns pairing, runtime identity, local Workers and credentials, local
permissions and prerequisites, adapter admission, Work Root/Workstream
directories, child-process execution, cancellation, logs, and diagnostics.
Cloud controls only remote scheduling state and authorization.

## Implemented evidence

- Workspace-created Workers synchronize as safe inventory and belong to exactly
  one owning Workspace.
- Cloud scheduling state distinguishes enabled, disabled, and draining from
  local readiness. Scheduler V7 assignment resolution no longer reads V6
  configured-Worker binding/credential rows.
- The real V7 E2E acceptance path exercises Cloud scheduling, Workspace Gateway,
  local Worker resolution, adapter admission/child execution, progress, and
  result persistence without a usable V6 binding candidate.
- V6 Worker mutation APIs, runtime fallback, and obsolete persistence were
  retired through forward migrations. Historical migrations remain unchanged.
- Adapter and Workspace release metadata use Ed25519 public-key verification;
  release workflows publish immutable records and read back packages for
  verification. See [release trust operations](../security/RELEASE_TRUST_AND_ROTATION.md).
- Workspace has V7 packages for Codex, Antigravity, Claude Code, Ollama, and the
  API Worker Types. Mock/protocol tests do not replace real provider acceptance.
- macOS menu-bar controls, build-injected version reporting, diagnostics, and
  production Workstream directory wiring are present. The native `.app` updater
  is not complete.

## Remaining release gates

### Phase 5 — production Worker acceptance

Run and record opt-in live acceptance for Codex with a real local account,
Antigravity with a real `agy` session, and API Workers with real credentials.
Confirm authentication expiry/remediation, model behavior, cancellation, and
stateful Workstream execution. Validate the Ollama local endpoint against a real
service. Keep secrets and billable calls out of routine CI.

### Phase 6 — failure, recovery, and security

The regression map in [V7 failure/recovery acceptance](V7_FAILURE_RECOVERY_ACCEPTANCE.md)
covers many deterministic cases. Its limits still include real provider expiry,
OS power/process failure, production release deployment, and complete
reconnect-time cancellation/update scenarios. The Phase 6 exit gate is open
until required cases pass at their operational boundaries and produce safe
diagnostics.

### Phase 7 — desktop runtime recovery

The macOS menu bar exposes connection status, active assignment count, app
navigation, pause/resume, drain, diagnostics/logs, and quit. The application
version is build-injected and shared across runtime/update reporting. However,
the current update mechanism is not a complete signed `.app` replacement flow:
download/verification, drain, bundle staging/replacement, restart, health
check, and rollback need to work as one native update transaction. Keep this
gate open until an end-to-end app update test proves the transaction.

## Initial V7 adapter protocol

Protocol version 1.0 contains these operations/events:

```text
initialize
validate
execute
progress
result
error
health
version
```

Interactive request/response input is not part of the initial protocol. Add it
only as a versioned extension when a production-supported adapter requires it.

## Historical architecture notes

Architecture v4–v6 and ADR-009/ADR-010 remain historical decision records.
Workstream isolation and ID-derived paths from ADR-009 remain current where
compatible. ADR-010's Cloud-created, multi-Workspace Worker bindings are
superseded by [ADR-012](../decisions/ADR-012-workspace-owned-local-workers.md).
No current runtime may infer ownership from those historical binding rules.

## Baseline declaration rule

Keep Architecture v7 labeled **active implementation target** until every
checkbox in the [release gate matrix](../roadmaps/ARCHITECTURE_V7_COMPLETION.md#v7-architecture-release-gates)
is supported by current evidence. Phase 8 documentation is converged enough to
state the current architecture, but it does not waive Phase 5–7 acceptance.
