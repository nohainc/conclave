# Architecture v7 Completion Plan

**Status:** Active completion plan  
**Baseline:** `main@633fe705154e7de7a1f0ded79fd3958e5a08eb07`  
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

# Phase 2 — Remove the V6 configured-Worker compatibility architecture

## Prerequisite

Do not start destructive cleanup until the Phase 1 V7 scheduler path and a real
V7 end-to-end assignment test pass.

## Goal

Leave one configured Worker model in product code.

## 2.1 Retire legacy Cloud Worker APIs

Remove the normal legacy routes and handlers for:
- Cloud-side Worker creation;
- Worker update/revoke as Cloud-owned configuration;
- Worker <-> Workspace binding CRUD;
- per-binding credential setup;
- per-binding reauthentication;
- per-binding credential read/revoke;
- legacy observability APIs that are meaningful only for V6 bindings.

Where a temporary compatibility endpoint must remain for migration, mark it
explicitly deprecated and ensure Conclave AX does not call it.

## 2.2 Remove legacy scheduler candidate resolution

Delete candidate resolution based on:
- `configured_workers`;
- `worker_workspace_bindings`;
- `workspace_worker_credentials`.

After removal, the scheduler must operate from:
- V7 Worker inventory;
- Cloud operational scheduling state;
- Workspace/Project grants;
- Project/Workstream execution policy;
- live Workspace runtime state;
- assignment/run state.

## 2.3 Migrate persistence

Do not rewrite already-applied production migrations.

Add a forward migration that:
- preserves required attribution/audit references;
- migrates any remaining pre-production data if needed;
- removes obsolete V6 tables/indexes once no runtime code reads them.

For disposable development environments, a clean schema reset is preferred over
maintaining permanent compatibility complexity.

## 2.4 Remove obsolete app/domain models

Remove stale:
- binding models;
- credential-per-binding models;
- callbacks;
- UI copy;
- fixtures;
- tests whose only purpose is the removed V6 architecture.

Retain historical ADRs and migration documents when useful, but mark them
historical rather than allowing them to define current behavior.

## 2.5 Remove obsolete Worker implementation paths

Audit the legacy `workers/` packages and old package-management paths.

Delete only components that have no remaining runtime/release responsibility.
Do not delete shared protocol or test utilities simply because their names are
old.

## Acceptance

- repository search finds no product code that creates a Cloud-owned configured
  Worker;
- scheduler has no V6 binding query;
- Conclave AX has no legacy Worker creation/binding path;
- clean schema starts with the V7 model;
- upgrade migration succeeds on a representative previous schema;
- all assignment attribution still resolves to Worker ID + Workspace ID +
  Worker Type.

## Exit gate

Exactly one Worker ownership model remains:

~~~text
Conclave Workspace creates Worker
-> safe Cloud projection
-> Cloud authorizes/schedules
-> owning Workspace executes
~~~

---

# Phase 3 — Production adapter trust and release pipeline

## Goal

Make adapter packages safe to distribute to untrusted client machines without
shipping a signing secret.

## 3.1 Replace shared-secret trust

Replace HMAC-based production verification with asymmetric signatures.

Recommended default:
- Ed25519;
- private key only in release infrastructure;
- public verification keys embedded/configured in Conclave Workspace;
- explicit key IDs;
- key rotation;
- revocation.

The signed payload must continue to bind:
- canonical manifest without its signature field;
- package file-tree digest.

Changing executable, permissions, auth strategy, secret requirements, platform,
or package contents must invalidate the signature.

Development-only fixture signing may remain separate, but production code must
fail closed if no trusted public key exists.

## 3.2 Apply the same trust principle to Workspace application updates

The Workspace update channel must not depend on a verification secret shipped
with the application.

Define:
- application release signing key;
- adapter release signing key(s);
- whether the same root trust anchors both;
- independent rotation/revocation policy.

Apple Developer ID/notarization complements, but does not replace, Conclave
release metadata verification.

## 3.3 Add first-party adapter release automation

Add a GitHub Actions release workflow that:

~~~text
build adapter
-> run protocol/provider-mock tests
-> create deterministic package
-> calculate archive + package digest
-> sign manifest
-> publish package to Cloud/R2
-> publish immutable catalog metadata
-> download it back
-> verify admission/health
~~~

Support:
- development;
- beta;
- stable;
- revoke;
- promote only by creating/verifying an appropriate immutable release record.

Private signing keys must be GitHub/production release secrets and must never be
committed or emitted in logs/artifacts.

## 3.4 Background update/revocation reconciliation

Workspace should periodically:
- refresh adapter catalog state;
- detect revoked active versions;
- stage supported updates;
- preserve last verified healthy rollback candidate;
- never switch active version without full verification + health check.

Define safe behavior when an active adapter becomes revoked during running work.

## Acceptance

- tampered archive fails;
- manifest-only tampering fails;
- revoked key fails;
- revoked release fails;
- wrong publisher/key fails;
- old trusted key can be rotated out;
- release workflow produces a package that a clean Workspace can install;
- no private signing key exists in desktop artifacts.

## Exit gate

Production adapter verification uses public-key trust and a repeatable
first-party release pipeline.

---

# Phase 4 — Complete first-party Worker coverage

## Goal

Ensure every Worker Type shown as normally supported by Conclave Workspace can
actually reach Ready and execute.

## 4.1 Claude Code

Current local setup exposes Claude Code but the V7 first-party adapter package
and full authentication path are incomplete.

Implement:
- `claude-code` V7 adapter package;
- supported CLI prerequisite/version policy;
- local Claude authentication validation;
- local authentication launch/remediation;
- headless execution contract;
- model/default handling;
- cancellation;
- Workstream CWD;
- normalized progress/result/errors;
- signed release.

Do not expose Claude Code as production-ready until this path passes.

## 4.2 Ollama

Implement:
- Ollama V7 adapter package;
- local endpoint reachability;
- version/health detection;
- model discovery;
- model selection validation;
- execution;
- cancellation;
- useful offline/error states.

Default local endpoints should be convenient but must remain explicit and safe.

## 4.3 Codex

Complete live acceptance for:
- real local ChatGPT/Codex session;
- supported CLI version;
- model selection;
- Workstream mutation;
- cancellation;
- authentication expiry/remediation.

## 4.4 Antigravity

Keep Worker Type naming as **Antigravity** and executable as `agy`.

Complete live acceptance for:
- real Google-account session;
- supported `agy` version;
- headless stream-json execution;
- optional model selection;
- cancellation;
- authentication expiry/remediation.

Do not reintroduce obsolete `antigravity auth status` instructions.

## 4.5 API Workers

For OpenAI API, Gemini API and Anthropic API:
- publish signed first-party releases;
- verify live credential acceptance with opt-in secrets;
- normalize provider errors;
- add model discovery where reliable;
- add streaming when useful.

Advanced tool/function calling is not a V7 architecture release gate unless a
core product workflow requires it.

## Acceptance matrix

Every production-supported Worker Type must pass:

| Capability | Tool-backed | API-backed | Local model |
| --- | ---: | ---: | ---: |
| prerequisite/endpoint validation | required | runtime validation | required |
| local authentication | required | API key | none/local |
| model validation | required | required | required |
| V7 adapter execution | required | required | required |
| cancellation | required | required | required |
| bounded/redacted output | required | required | required |
| signed release | required | required | required |

## Exit gate

Every Worker Type visible in the normal Add Worker production catalog can
become Ready and execute through a supported V7 adapter.

---

# Phase 5 — Real V7 end-to-end acceptance

## Goal

Replace schema-only confidence with behavioral acceptance of the actual product
path.

## 5.1 Reclassify the current solo acceptance test

The current Cloud `v7-solo-acceptance.test.ts` validates useful schema and
lifecycle invariants, but it inserts inventory and a completed assignment
directly.

Keep that coverage, but rename/reclassify it as schema/lifecycle acceptance so
it is not mistaken for full system acceptance.

## 5.2 Add a true V7 integration harness

The harness must exercise:

~~~text
local Worker registry
-> Workspace hello
-> full Worker inventory sync
-> Cloud persistence
-> Project Workspace Grant
-> Workstream policy
-> scheduler selection
-> assignment creation
-> Workspace Gateway dispatch
-> Workspace resolves local Worker
-> verified adapter child process
-> ID-only Workstream CWD
-> progress/result
-> Cloud assignment completion
-> Conclave AX/read model result
~~~

Use a deterministic fake V7 adapter for normal CI.

Do not bypass:
- scheduler;
- Gateway;
- local registry;
- adapter admission/execution.

## 5.3 Add failure/recovery scenarios

Automate:
- Workspace disconnect/reconnect;
- duplicate hello;
- duplicate inventory snapshot;
- stale revision;
- Worker removed locally;
- credential becomes expired;
- prerequisite disappears;
- adapter crash;
- child tool crash;
- cancellation;
- forced process-tree kill;
- Cloud cancel during reconnect;
- adapter update failure/rollback;
- Workspace re-pair;
- stateful Workstream lease/fencing conflict.

## 5.4 Add security acceptance

Verify:
- wrong Workspace cannot publish another Worker's inventory;
- Cloud cannot override local Worker permissions;
- Cloud cannot select arbitrary executable;
- Cloud cannot select arbitrary CWD;
- path traversal is rejected;
- API keys/session tokens never appear in Cloud DB/event payloads/logs;
- malicious/tampered adapter package is rejected;
- cross-user scheduling without explicit authorization fails.

## 5.5 Add opt-in live acceptance

Separate, non-default workflows may test:
- real Codex;
- real Antigravity;
- real OpenAI API;
- real Gemini API;
- real Anthropic API.

These jobs:
- require explicitly configured secrets/accounts;
- must never run on untrusted PRs;
- must not log provider credentials;
- are not required for ordinary contributor CI.

## Exit gate

A clean V7 Worker can complete a real Work assignment through the same
Cloud/Gateway/runtime/adapter path used by the product.

---

# Phase 6 — Finish Conclave Workspace as a production desktop runtime

## Goal

Move from a functional desktop vertical slice to an always-on execution
product.

## 6.1 macOS menu-bar/background lifecycle

Implement:
- menu-bar status;
- connected/offline/attention state;
- active assignment count;
- Open Conclave Workspace;
- Open Conclave AX;
- Pause new work;
- Resume;
- Drain;
- Diagnostics/logs;
- Quit.

Closing the main window must not stop execution.

Quit with active assignments must offer clear safe behavior:
- cancel quit;
- drain then quit;
- explicit cancel-and-quit where allowed.

## 6.2 Workspace application version

Use the build-injected Workspace version as the runtime's authoritative current
version.

Remove hard-coded update-version values such as `0.1.0` from production update
checks.

The same version must be reported consistently in:
- machine facts;
- diagnostics;
- update checks;
- package name;
- release metadata.

## 6.3 Complete native application update flow

The existing update controller provides useful discovery, verification, staging
and rollback primitives.

Complete the macOS product-specific flow for:
- signed `.app` bundle update;
- restart/bootstrap;
- rollback;
- active-assignment drain;
- failure recovery;
- version reporting after restart.

## 6.4 Reauthentication and local attention UX

Provide clear local actions for:
- expired account/session;
- missing CLI;
- unsupported CLI version;
- revoked adapter;
- missing local endpoint;
- denied permission;
- update required.

AX may request attention, but the action is completed locally.

## 6.5 Diagnostics

Expose:
- Cloud connection state;
- Workspace/runtime IDs without secrets;
- app version;
- adapter versions;
- Worker readiness;
- prerequisite versions;
- active assignments;
- recent bounded errors;
- Work Root;
- last inventory sync;
- last update check.

## Exit gate

Conclave Workspace can run continuously and recover predictably without the main
window remaining open.

---

# Phase 7 — Documentation and baseline convergence

## Goal

Make the repository describe one current architecture after implementation
converges.

## Update

- Architecture v7 status;
- V7 implementation audit;
- V7 implementation roadmap/status checkboxes;
- technology stack;
- application boundaries;
- root roadmap;
- README;
- deployment/release guidance;
- adapter release instructions;
- security/release-key rotation documentation.

## Historical documents

Keep older ADRs and roadmaps where they explain evolution, but mark superseded
ownership/cardinality rules clearly.

## Adapter protocol clarification

The implemented initial protocol has:
- initialize;
- validate;
- execute;
- progress;
- result;
- error;
- health;
- version.

`request-input` is not part of the initial V7 schema. Either:
- add a versioned interactive input request/response contract when a supported
  adapter needs it; or
- keep it explicitly deferred in Architecture v7.

Do not imply it already exists.

## Exit gate

Change V7 status to **Implemented baseline** only when all architecture release
gates below pass.

---

# V7 architecture release gates

V7 is implemented when all of the following are true:

- [ ] Cloud schedules Workspace-owned V7 Workers without V6 binding
  dependency.
- [ ] Cloud scheduling state supports enabled/disabled/draining independently
  of local readiness.
- [ ] Legacy Cloud-created configured Worker/binding APIs are removed from the
  current product architecture.
- [ ] V6 binding persistence is no longer required for execution.
- [ ] Production adapter verification uses asymmetric public-key trust.
- [ ] First-party adapter release automation exists.
- [ ] Codex and Antigravity pass real opt-in acceptance.
- [ ] Every Worker Type exposed as production-supported can become Ready and
  execute.
- [ ] A real automated V7 end-to-end assignment passes through scheduler,
  Workspace Gateway and adapter child process.
- [ ] Inventory reconnect/removal/stale-revision behavior is tested.
- [ ] Failure/recovery and security acceptance pass.
- [ ] macOS build/sign/notarize procedure passes.
- [ ] Desktop-to-Cloud enrollment + Gateway smoke passes.
- [ ] Workspace runtime uses the actual packaged application version.
- [ ] Background/menu-bar lifecycle is production-usable.
- [ ] Provider secrets never enter Cloud state, events, artifacts or logs.

## Recommended PR sequence

Keep completion work reviewable and reversible:

1. **Phase 1 — V7 scheduling state + V7-only candidate contract**
2. **PR B — real V7 end-to-end integration harness**
3. **PR C — remove V6 scheduler/API/persistence compatibility**
4. **PR D — asymmetric adapter/release trust**
5. **PR E — first-party adapter release workflow**
6. **PR F — Claude Code + Ollama V7 adapters**
7. **PR G — live adapter acceptance + reconciliation/failure hardening**
8. **PR H — macOS menu-bar/update/diagnostics maturity**
9. **PR I — final V7 docs/baseline declaration**

PR B deliberately precedes destructive V6 cleanup. The real V7 path should be
proven before the compatibility path is deleted.

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
