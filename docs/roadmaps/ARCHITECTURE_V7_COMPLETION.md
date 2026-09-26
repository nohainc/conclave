# Architecture v7 Completion Plan

**Status:** Active completion plan  
**Baseline:** `main@2c740092fd0e558880873894fe997454a989fef2`  
**Date:** 2026-09-26  
**Architecture:** [Architecture v7](../architecture/ARCHITECTURE_V7.md)  
**Decision:** [ADR-012](../decisions/ADR-012-workspace-owned-local-workers.md)  
**Detailed roadmap:** [Architecture v7 implementation](ARCHITECTURE_V7_IMPLEMENTATION.md)

## Purpose

The v7 desktop vertical slice is now implemented: Conclave Workspace can pair
with Cloud, run the real Workspace runtime, create local Workers, synchronize
safe Worker inventory, execute V7 adapters, build as a native macOS
application, and verify a real enrollment + Workspace Gateway connection.

v7 is not yet the implemented baseline because the repository still contains
two execution models and several production release gates remain open.

This plan defines the remaining work required to move from:

~~~text
V7 desktop vertical slice
+ V7 inventory/scheduling path
+ V6 compatibility path
~~~

to:

~~~text
one V7 Worker model
+ production adapter trust
+ complete first-party Worker coverage
+ real end-to-end acceptance
+ production-grade desktop runtime
~~~

## Completion principles

1. **One Worker ownership model.** A configured Worker is created locally and
   belongs to exactly one Workspace.
2. **Split authority.** Workspace owns local Worker configuration, credentials,
   permissions and readiness. Cloud owns Project/Workstream authorization and
   remote operational scheduling state.
3. **No secret migration to Cloud.** Provider secrets remain local.
4. **Prove before delete.** Remove the V6 execution path only after the V7
   vertical path executes end to end through the real scheduler and Workspace
   Gateway.
5. **Public-key release trust.** A distributable client must never contain a
   signing secret.
6. **Acceptance must exercise behavior.** Database fixture insertion alone is
   not an end-to-end acceptance test.
7. **Do not widen scope unnecessarily.** Rich provider features such as advanced
   tool calling may continue after the architecture is declared complete when
   they are not required for the core V7 contract.

---

# Phase 1 — Make Cloud execution purely V7-shaped

**Status:** ✅ Implemented on `main@2c740092`  
**Remaining verification:** behavioral end-to-end proof is Phase 2, not a Phase 1 code gap.

## Goal

Finish the Cloud-side Worker model so a synchronized Workspace-owned Worker is
the complete scheduling resource rather than a compatibility projection beside
the V6 binding model.

## 1.1 Add Cloud-owned Worker operational state

Local readiness and Cloud scheduling state are different concepts.

Add an explicit Cloud-owned state for each V7 Worker:

~~~text
enabled
disabled
draining
~~~

The exact persistence shape may be a dedicated table or equivalent normalized
state, but ownership must remain clear:

~~~text
Workspace-owned:
- Worker existence
- credential state
- local permissions
- local concurrency ceiling
- adapter/prerequisite readiness

Cloud-owned:
- scheduling enabled/disabled/draining
- optional Cloud concurrency ceiling
- Project/Workstream authorization
~~~

Effective scheduling is the intersection:

~~~text
local Ready
AND Cloud enabled
AND Workspace online
AND active Workspace Grant
AND Project/Workstream policy
AND capability/model compatibility
AND local/Cloud capacity
~~~

### Required API behavior

Add V7 operational-control endpoints for:
- enable scheduling;
- disable scheduling;
- drain;
- read current scheduling state.

Conclave AX Worker detail must use these V7 controls.

Cloud controls must never:
- modify provider credentials;
- approve local permissions;
- change the Worker to another Workspace;
- make an unready Worker executable.

### Drain semantics

Define drain explicitly:

- no new assignments;
- running assignments continue;
- state becomes disabled or remains drained according to the chosen product
  action after active assignments reach zero;
- audit records who requested the drain and when it completed.

## 1.2 Make scheduler V7-first and V7-complete

Current scheduler logic reads both:
- `workspace_worker_inventory`;
- legacy configured Worker + Workspace binding + credential rows.

Refactor candidate selection so the V7 path contains every field required for
authorization and dispatch without manufacturing V6-shaped compatibility data.

Remove V7 assumptions such as treating:

~~~text
local status == ready
~~~

as equivalent to:

~~~text
Cloud scheduling enabled
~~~

The selection explanation should use V7 vocabulary. Remove legacy wording such
as `configured_worker_bound` for V7 candidates.

## 1.3 Complete inventory reconciliation

A full Workspace snapshot must be authoritative for that Workspace.

Verify:
- initial full inventory;
- periodic full inventory;
- reconnect;
- stale/equal revision rejection;
- explicit tombstones;
- Worker omitted from a later authoritative snapshot;
- Workspace re-pairing;
- duplicate Worker ID submitted by another Workspace.

Define when omission creates a tombstone versus when Cloud waits for a later
snapshot. The rule must be deterministic and idempotent.

## 1.4 Finish Project/Workstream policy integration

V7 Workers must support:
- explicit Worker IDs;
- Worker Type constraints;
- capabilities;
- models;
- granted Workspaces;
- stateful Primary Workspace enforcement;
- stateless scheduling across eligible granted Workspaces.

No policy may authorize a Worker on a Workspace other than its owning
Workspace.

## Acceptance

Automated tests must prove:

1. local Ready + Cloud disabled is not scheduled;
2. draining Worker receives no new work;
3. Cloud cannot schedule a locally disabled/unready Worker;
4. Project and Workstream policy narrow eligibility correctly;
5. stateful work selects only the Primary Workspace;
6. stateless work can select an eligible Worker from another granted
   Workspace;
7. local concurrency ceiling is never exceeded;
8. inventory removal/reconnect behavior is idempotent.

## Exit gate

Phase 1 is complete when the scheduler can execute the V7 model without reading
V6 Worker bindings for a V7 assignment.

---

# Phase 2 — Prove the real V7 end-to-end execution path

**Status:** 🔄 Next active phase

## Why this phase moved ahead of cleanup

Phase 1 now proves at unit/integration level that a V7 inventory candidate can
be selected without reading the V6 binding query, and that Cloud scheduling
state is independent from local readiness.

That is necessary but not sufficient before deleting the compatibility
architecture.

The existing `apps/cloud/test/v7-solo-acceptance.test.ts` remains primarily a
schema/lifecycle test because it inserts Worker inventory and completed
assignment state directly. It does not prove the real runtime path:

~~~text
scheduler
-> Workspace Gateway
-> Conclave Workspace
-> local Worker registry
-> admitted V7 adapter
-> child process
-> Workstream CWD
-> result back to Cloud
~~~

Therefore Phase 2 is the mandatory **migration-safety gate** for Phase 3.

## Goal

Create a deterministic automated acceptance harness that executes the same V7
control and runtime path used by the product without requiring a live/billable
AI provider.

## 2.1 Keep schema acceptance, but classify it correctly

Keep the current solo/schema coverage because it validates valuable relational
and ownership invariants.

Rename it or document it clearly as schema/lifecycle acceptance so it is not
used as evidence that the runtime execution path works end to end.

It may continue to verify:
- Workspace-owned Worker persistence;
- Project/Workspace grants;
- Workstream policy rows;
- assignment attribution schema;
- absence of legacy AI Account requirements.

It must not be the Phase 2 exit test.

## 2.2 Build a deterministic V7 test adapter

Use a fake/test adapter package that implements the real V7 adapter protocol.

The adapter must:
- be admitted through the V7 package/admission path;
- have a deterministic signed test manifest;
- execute as a child process;
- emit at least progress + result;
- record/return its current working directory;
- support cancellation if practical in the same harness;
- require no provider account, external network, or billable API.

Do not mock away adapter admission or child-process execution.

## 2.3 Exercise the real Workspace runtime

The test must create/use the same runtime components as production where
practical:

~~~text
LocalConfiguredWorkerRegistry
-> Workspace runtime
-> Workspace Gateway connection
-> workspace.hello
-> full V7 Worker inventory sync
~~~

Verify that:
- Worker ID is generated/owned locally;
- safe inventory reaches Cloud;
- no credential reference, API key, session token, cookie, or arbitrary local
  path enters the Cloud projection;
- the Worker is bound to exactly one Workspace;
- Cloud scheduling is explicitly enabled before it becomes eligible.

## 2.4 Exercise the real Cloud scheduling path

Create the minimum real Cloud state required for work:
- User/Project;
- Workspace;
- active Project Workspace Grant;
- Workstream;
- Workstream execution policy;
- Work Request / Run or the current canonical execution entrypoint.

Then call the real scheduler/candidate selection path.

Verify:
- selected `configuredWorkerId` is the local V7 Worker ID;
- selected `workerTypeId` remains the adapter/integration type;
- selected Workspace is the Worker's owning Workspace;
- Cloud scheduling must be `enabled`;
- locally disabled/unready Worker is rejected;
- Cloud disabled/draining Worker is rejected for new work;
- local and Cloud concurrency ceilings are respected;
- V7 candidate selection succeeds when the V6 binding query has no usable
  candidate and, ideally, is not read for that V7 selection.

## 2.5 Dispatch through the real Workspace Gateway

Do not manually mark the assignment complete.

The test must:
- create the assignment through the normal execution path;
- dispatch it through the Workspace Gateway;
- receive it in Conclave Workspace;
- resolve the local Worker from the local registry;
- resolve the admitted V7 adapter;
- execute the adapter as a child process;
- return progress/result through the Gateway;
- persist the final Cloud assignment/result state.

## 2.6 Verify the Workstream filesystem contract

The child adapter must execute with the runtime-resolved ID-only Workstream CWD:

~~~text
<work-root>/<project-id>/<workstream-id>/
~~~

Verify:
- Project/Workstream names do not define the path;
- Workspace/Worker IDs do not define the path;
- adapter input cannot override arbitrary CWD;
- the fake adapter can read/write a deterministic test file when permissions
  allow it.

## 2.7 Add the minimum cleanup-safety scenarios

Before Phase 3 begins, the automated harness must also cover:

1. **No V6 dependency**
   - V7 work completes with no usable V6 binding candidate.
2. **Cloud scheduling**
   - disabled and draining Workers receive no new work.
3. **Local readiness**
   - locally disabled / needs-attention Worker is ineligible.
4. **Worker removal**
   - local tombstone or authoritative snapshot omission makes the Worker
     ineligible.
5. **Inventory revisions**
   - stale/equal invalid updates are rejected according to the V7 contract.
6. **Reconnect**
   - Workspace reconnect + authoritative inventory produces a usable V7 Worker
     again without creating a second identity.
7. **Cancellation**
   - cancellation reaches the Workspace and terminates the adapter/process tree
     where feasible in the harness.
8. **Secret boundary**
   - no provider/local secure-store secret is present in Cloud persistence,
     assignment payloads, events, or captured logs.

More exhaustive failure/security testing remains a later hardening phase; Phase
2 contains the subset required to make V6 deletion safe.

## 2.8 CI placement

The deterministic fake-adapter E2E test should run in normal trusted CI and must
not require:
- Codex login;
- Google/Antigravity login;
- OpenAI/Gemini/Anthropic keys;
- external provider quota.

Keep real-provider acceptance opt-in and separate.

## Phase 2 exit gate

Phase 2 is complete only when a clean V7 Worker completes a real Work assignment
through:

~~~text
scheduler
-> Workspace Gateway
-> Conclave Workspace
-> local Worker registry
-> V7 adapter admission/resolution
-> adapter child process
-> ID-only Workstream CWD
-> result returned and persisted in Cloud
~~~

and that path does not require a V6 Worker binding.

> **Do not start destructive Phase 3 cleanup before this gate passes.**

---

# Phase 3 — Remove the V6 configured-Worker compatibility architecture

**Prerequisite:** Phase 2 E2E migration-safety gate passes.

## Goal

Leave one configured Worker model in product code.

## 3.1 Freeze legacy mutation before deletion

Before removing tables, make the compatibility boundary explicit:
- Conclave AX must not call legacy Cloud Worker creation/binding APIs;
- no new feature may add a dependency on V6 Worker bindings;
- compatibility endpoints, if temporarily retained during the cleanup PR, must
  be marked deprecated/internal.

## 3.2 Remove legacy scheduler fallback

Delete candidate resolution based on:
- `configured_workers`;
- `worker_workspace_bindings`;
- `workspace_worker_credentials`.

After removal, the scheduler must operate from:
- `workspace_worker_inventory`;
- `v7_worker_scheduling`;
- Workspace runtime identity/online state;
- Project Workspace Grants;
- Project/Workstream execution policy;
- assignment/run state.

Retain the Phase 2 E2E test unchanged as the regression gate.

## 3.3 Retire legacy Cloud Worker APIs

Remove legacy handlers/routes for:
- Cloud-side configured Worker creation;
- configured Worker update/revoke as Cloud-owned configuration;
- Worker <-> Workspace binding CRUD;
- per-binding setup/reauthentication;
- per-binding credential read/revoke;
- legacy observability endpoints that only describe V6 binding state.

Do not remove catalog/Worker Type APIs that remain part of V7 infrastructure.

## 3.4 Remove obsolete app/domain models

Remove stale:
- configured Worker binding models;
- credential-per-binding models;
- callbacks;
- migration-only UI copy;
- fixtures;
- tests whose sole purpose is the removed V6 architecture.

Do not remove historical ADRs; mark superseded rules clearly instead.

## 3.5 Forward-migrate persistence

Do not rewrite already-applied migrations.

Add a forward migration that:
- preserves assignment/audit attribution that must remain queryable;
- migrates any still-required pre-production state if necessary;
- drops obsolete V6 tables/indexes only after runtime/API code no longer reads
  them.

For disposable development environments, prefer a clean V7 schema over
permanent compatibility complexity.

## 3.6 Audit legacy `workers/` and package paths

Classify each legacy package as:
- still required shared infrastructure;
- historical/test-only;
- V6 runtime implementation that can be deleted.

Delete only confirmed obsolete code. Names alone are not sufficient evidence.

## Phase 3 acceptance

- Phase 2 E2E remains green;
- scheduler contains no V6 binding candidate query;
- repository contains no active Cloud-side configured Worker creation flow;
- Conclave AX contains no Worker binding/setup path;
- V7 assignments still preserve Worker ID + Workspace ID + Worker Type
  attribution;
- migration succeeds from a representative pre-cleanup schema;
- no current runtime code reads dropped V6 tables.

## Phase 3 exit gate

Exactly one Worker ownership/execution model remains:

~~~text
Conclave Workspace creates Worker
-> safe Cloud inventory
-> Cloud scheduling + authorization
-> owning Workspace executes
~~~

---

# Phase 4 — Production adapter and application release trust

## Goal

Make adapter and Workspace releases verifiable by a public client without
shipping a signing secret.

## 4.1 Replace production HMAC trust

Replace shared-secret production verification with asymmetric signatures.

Recommended:
- Ed25519;
- private key only in release infrastructure;
- trusted public key(s) in Conclave Workspace;
- explicit key IDs;
- rotation;
- revocation.

The signed adapter payload must continue to bind:
- canonical manifest without the signature field;
- package file-tree digest.

Development fixture signing may remain separate, but production paths must fail
closed without a trusted public key.

## 4.2 Apply equivalent trust to Workspace updates

Define release trust for the native Conclave Workspace application:
- application release signing key;
- public verification key;
- key ID/rotation policy;
- interaction with Apple Developer ID + notarization.

Apple platform signing complements Conclave release metadata verification; it
does not replace it.

## 4.3 Add first-party release automation

Add a repeatable GitHub Actions workflow:

~~~text
build
-> test
-> deterministic package
-> digest
-> sign
-> upload
-> publish immutable catalog metadata
-> download
-> verify admission/health
~~~

Support development/beta/stable and revocation.

## 4.4 Background update/revocation reconciliation

Workspace should periodically:
- refresh adapter catalog state;
- detect revoked active versions;
- stage supported updates;
- retain the last verified healthy rollback candidate;
- never activate without full signature/digest/platform/permission/health
  verification.

## Phase 4 exit gate

Production adapter/application verification uses asymmetric public-key trust and
first-party release publication is repeatable.

---

# Phase 5 — Complete production Worker Type coverage

## Goal

Every Worker Type shown as production-supported in Conclave Workspace can
actually become Ready and execute through V7.

## 5.1 Claude Code

Complete:
- V7 adapter package;
- CLI prerequisite/version validation;
- local authentication validation/launch/remediation;
- headless execution;
- model/default handling;
- cancellation;
- Workstream CWD;
- normalized progress/result/error;
- signed published release.

## 5.2 Ollama

Complete:
- V7 adapter package;
- endpoint reachability;
- version/health check;
- model discovery;
- model selection validation;
- execution/cancellation;
- signed published release.

## 5.3 Codex and Antigravity

Run opt-in live acceptance against:
- real Codex/ChatGPT local session;
- real Google/Antigravity `agy` session.

Verify authentication expiry/remediation, model selection, cancellation and
stateful Workstream execution.

## 5.4 API Workers

For OpenAI API, Gemini API and Anthropic API:
- publish production-signed releases;
- run opt-in credential acceptance;
- normalize provider failures;
- add model discovery where reliable;
- add streaming where product value justifies it.

Advanced tool/function calling is not automatically a V7 architecture blocker.

## Phase 5 exit gate

Every Worker Type exposed as production-supported can be installed/admitted,
validated and executed through V7.

---

# Phase 6 — Failure, recovery and security hardening

## Goal

Extend the Phase 2 migration-safety harness into full operational/security
acceptance.

## Failure/recovery coverage

Add:
- repeated Cloud disconnect/reconnect;
- duplicate hello/snapshot;
- adapter crash;
- provider/tool crash;
- credential expiry;
- missing/outdated CLI after previously being Ready;
- adapter update failure + rollback;
- Workspace re-pair;
- Cloud cancel during reconnect;
- stateful lease/fencing conflict;
- local Worker deletion during queued/running work;
- app update while work is active.

## Security coverage

Verify:
- wrong Workspace cannot publish/update another Worker's inventory;
- Cloud cannot broaden local permissions;
- Cloud cannot choose arbitrary executable/CWD;
- path traversal is rejected;
- malicious/tampered adapter packages fail;
- revoked keys/releases fail;
- secret redaction holds in logs/progress/errors;
- cross-user scheduling requires explicit authorization;
- process-tree cancellation prevents escaped child execution.

## Observability

Ensure failures produce safe, actionable diagnostics without reintroducing token
or cost Usage accounting.

## Phase 6 exit gate

Failure behavior is explicit/idempotent and Workspace remains the machine
security boundary under adversarial acceptance tests.

---

# Phase 7 — Finish Conclave Workspace as a production desktop runtime

## Goal

Move from a functional native vertical slice to an always-on execution product.

## 7.1 macOS menu-bar/background lifecycle

Implement:
- menu-bar status;
- connected/offline/attention state;
- active assignment count;
- Open Conclave Workspace;
- Open Conclave AX;
- pause/resume new work;
- drain;
- diagnostics/logs;
- quit.

Closing the main window must not stop the runtime.

## 7.2 Use the real packaged app version

Use the build-injected Workspace version as the authoritative runtime version.

Remove hard-coded production update values such as `0.1.0`.

Report the same version in:
- runtime facts;
- diagnostics;
- update checks;
- package/release metadata.

## 7.3 Complete native update/restart

Finish the macOS `.app` update flow:
- download/verify;
- drain active work;
- stage;
- replace/restart;
- health-check;
- rollback on failure.

## 7.4 Reauthentication/local attention UX

Provide local actions for:
- expired account/session;
- missing/outdated prerequisite;
- revoked adapter;
- missing local endpoint;
- denied permission;
- required update.

## 7.5 Diagnostics

Expose safe:
- Cloud connection state;
- runtime/Workspace identity;
- app version;
- adapter versions;
- Worker readiness;
- prerequisite versions;
- active assignments;
- bounded recent errors;
- Work Root;
- last inventory sync/update check.

## Phase 7 exit gate

Conclave Workspace runs continuously, recovers predictably, and does not depend
on the main window remaining open.

---

# Phase 8 — Documentation and V7 baseline declaration

## Goal

Make the repository describe one current implemented architecture.

## Update

- Architecture v7 status;
- V7 implementation audit;
- detailed implementation roadmap checkboxes;
- technology stack;
- applications/product boundaries;
- root roadmap/README;
- deployment/release guidance;
- key rotation/revocation procedures;
- adapter release instructions.

Keep historical ADRs/roadmaps, but clearly mark superseded ownership rules.

## Protocol clarification

The initial implemented V7 protocol includes:

~~~text
initialize
validate
execute
progress
result
error
health
version
~~~

Interactive request/response input remains a future versioned extension unless a
production-supported adapter requires it.

## Phase 8 exit gate

Only after all architecture release gates pass, change V7 from **active
implementation target** to **implemented baseline**.

---

# V7 architecture release gates

V7 is implemented when all of the following are true:

- [x] A V7 inventory candidate can be selected without consulting the V6
  binding query.
- [x] Cloud scheduling state supports enabled/disabled/draining independently
  of local readiness.
- [x] Full inventory snapshot omission creates a safe tombstone/disable state
  and cross-Workspace Worker ID reuse is rejected.
- [ ] A real automated V7 end-to-end assignment passes through scheduler,
  Workspace Gateway, local Worker registry and adapter child process.
- [ ] The real V7 E2E path succeeds with no usable V6 binding candidate.
- [ ] Legacy V6 scheduler fallback is removed.
- [ ] Legacy Cloud-created configured Worker/binding APIs are removed from the
  current product architecture.
- [ ] V6 binding persistence is no longer required for execution.
- [ ] Production adapter/application verification uses asymmetric public-key
  trust.
- [ ] First-party adapter release automation exists.
- [ ] Every Worker Type exposed as production-supported can become Ready and
  execute.
- [ ] Codex and Antigravity pass real opt-in acceptance.
- [ ] Reconnect/removal/stale-revision behavior passes behavioral E2E
  acceptance.
- [ ] Failure/recovery and security acceptance pass.
- [ ] macOS build/sign/notarize procedure passes.
- [x] Desktop-to-Cloud enrollment + Workspace Gateway smoke procedure exists.
- [ ] Workspace runtime uses the actual packaged application version.
- [ ] Background/menu-bar lifecycle is production-usable.
- [ ] Provider secrets never enter Cloud state, events, artifacts or logs in
  E2E/security acceptance.

## Current phase status

| Phase | Status | Gate |
| --- | --- | --- |
| 1 — V7 Cloud scheduling/inventory | ✅ Implemented | Unit/integration contract complete |
| 2 — Real V7 E2E migration-safety gate | 🔄 Next | Required before V6 cleanup |
| 3 — Remove V6 compatibility | ⏸ Blocked | Requires Phase 2 |
| 4 — Production release trust | Pending | Required for public distribution |
| 5 — Production Worker coverage | Pending | Required for supported catalog |
| 6 — Failure/security hardening | Pending | Required for V7 baseline |
| 7 — Desktop runtime maturity | Pending | Required for production UX |
| 8 — Baseline/docs declaration | Pending | Requires all release gates |

## Recommended PR sequence from current main

Keep completion work reviewable and reversible:

1. **Phase 2 / PR B — real V7 end-to-end integration harness**
2. **Phase 3 / PR C — remove V6 scheduler/API/persistence compatibility**
3. **Phase 4 / PR D — asymmetric adapter + Workspace release trust**
4. **Phase 4 / PR E — first-party adapter release workflow**
5. **Phase 5 / PR F — Claude Code + Ollama V7 adapters**
6. **Phase 5/6 / PR G — live adapter acceptance + failure/security hardening**
7. **Phase 7 / PR H — macOS menu-bar/update/diagnostics maturity**
8. **Phase 8 / PR I — final V7 docs/baseline declaration**

Phase 1 is already implemented in `main@2c740092`. Phase 2 deliberately
precedes destructive V6 cleanup. The real V7 path must be proven before the
compatibility path is deleted.

## Final target

~~~text
Conclave AX
    |
    v
Conclave Cloud
    |
    | Project/Workstream authorization
    | Worker scheduling state
    | immutable Assignment
    v
Conclave Workspace
    |
    | local Worker registry
    | local credentials + permissions
    | verified adapter package
    v
Worker adapter child process
    |
    v
Codex / Antigravity / Claude Code / provider API / local model
~~~

There is one configured Worker model, one machine authority, one scheduling
contract, and one execution path.
