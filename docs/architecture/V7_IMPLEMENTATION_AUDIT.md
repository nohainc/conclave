# Architecture v7 Implementation Audit — Current Main

**Reviewed baseline:** `main@633fe705154e7de7a1f0ded79fd3958e5a08eb07`  
**Audit date:** 2026-09-26  
**Target:** [Architecture v7](ARCHITECTURE_V7.md)  
**Completion plan:** [Architecture v7 completion plan](../roadmaps/ARCHITECTURE_V7_COMPLETION.md)

## Executive assessment

Architecture v7 is **substantially implemented but not yet the implemented
baseline**.

The latest desktop-convergence work closed the earlier vertical-slice gaps:

- Conclave Workspace Flutter desktop and the headless entrypoint now compose the
  same real Cloud-connected runtime;
- the desktop pairing flow redeems one-time Workspace enrollments;
- runtime bearer credentials are stored separately from non-secret local
  registration metadata;
- the native macOS build/package script exists and CI builds the desktop app;
- the real enrollment + Workspace Gateway smoke path exists;
- Conclave AX no longer exposes the normal legacy Cloud-side Add Worker/binding
  setup flow;
- Antigravity uses the `agy` integration contract;
- safe Workspace-owned Worker inventory is visible in Conclave AX.

The remaining work is now concentrated in five architectural/release areas:

1. **The V7 scheduler path needs independent verification.** Inventory
   candidates now use Cloud-owned scheduling state and Workspace-owned local
   readiness. The legacy V6 candidate query remains for compatibility.
2. **Full Cloud-to-AX operational acceptance remains open.** Enable/disable/
   drain routes and snapshot reconciliation exist, but need executable tests
   across state transitions and reconnect scenarios.
3. **Legacy V6 APIs and persistence remain active.** Cloud still exposes
   configured Worker creation/binding/credential routes and retains the V6
   configured Worker tables.
4. **Production adapter trust is not ready for public distribution.** Package
   verification is still based on shared-secret HMAC trust rather than
   asymmetric signatures with public verification keys.
5. **Acceptance is not yet end to end.** The current V7 solo acceptance test is
   a useful schema/lifecycle test, but it inserts inventory and completed
   assignment state directly rather than exercising scheduler -> Gateway ->
   Workspace -> adapter execution.

v7 should therefore be described as:

> **desktop vertical slice implemented; architecture convergence and production
> release gates still in progress.**

## Product boundary

### Conclave AX

Conclave AX is the **web application**.

It owns:
- human sign-in;
- Projects and Workstreams;
- Discuss and Work;
- Workspace creation/grants;
- remote Worker inventory;
- Cloud scheduling/authorization controls;
- results, artifacts and audit;
- downloads/onboarding.

It does not create/authenticate local Workers.

### Conclave Workspace

Conclave Workspace is the **desktop application/runtime** installed on the
execution computer.

It owns:
- pairing;
- persistent Cloud connection;
- machine facts;
- Work Root and Workstream directories;
- local Worker creation/edit/removal;
- provider authentication/API credentials;
- local permissions;
- adapter packages;
- child process execution;
- diagnostics and updates.

All configured Workers originate here.

## Desktop pairing and runtime status

The intended V7 flow is implemented:

~~~text
Conclave AX web
-> Create Workspace
-> Connect machine
-> create one-time workspace_enrollment
-> show pairing code

Conclave Workspace desktop
-> enter pairing code
-> POST /api/workspace-runtime/enroll
-> receive runtime ID + bearer token
-> store bearer token in OS secure store
-> store non-secret registration locally
-> connect /api/workspace-gateway/connect
-> workspace.hello
-> inventory sync
~~~

The repository also provides:

~~~text
bash scripts/build-workspace-macos.sh
~~~

and:

~~~text
CONCLAVE_ENROLLMENT_TOKEN=...   bash scripts/test-workspace-cloud-connection.sh
~~~

The remaining release work is production sign/notarize execution, update
maturity, menu-bar/background UX, and full failure/recovery acceptance.

## Worker Type naming

Worker Type names identify the **execution integration**, not the subscription
brand and not a model family.

### Correct

- **Codex** — invokes Codex CLI. Authentication may be a ChatGPT account.
- **Antigravity** — invokes Google Antigravity CLI (`agy`).
- **Claude Code** — invokes Claude Code.
- **OpenAI API** — direct provider API.
- **Gemini API** — direct Gemini API.
- **Anthropic API** — direct Anthropic API.
- **Ollama** — local Ollama service.

### Incorrect / misleading

- **ChatGPT Worker** for the Codex CLI integration;
- **Gemini Worker** when the actual integration is Antigravity;
- one Worker Type per model such as Gemini Pro, GPT-5.x or Claude Sonnet.

If Conclave later supports a distinct Gemini CLI integration, it should be a
separate Worker Type rather than being conflated with Antigravity or Gemini API.

## Current implementation strengths

### Workspace-local Worker ownership

The local Worker registry is implemented with:
- immutable local Worker IDs;
- direct Workspace ownership;
- revisioned/checksummed local persistence;
- secure credential references rather than plaintext provider secrets;
- local permissions/model/concurrency configuration;
- safe Cloud inventory projection.

### Adapter execution

The V7 adapter path provides:
- signed-manifest/package admission;
- digest verification;
- explicit package-relative executable;
- permission checks;
- bounded structured protocol;
- per-assignment child processes;
- bounded/redacted output;
- Workstream CWD isolation;
- process-tree cancellation;
- per-Worker local concurrency;
- package health checks and rollback.

### First-party adapter foundation

Implemented V7 adapter packages include:
- Codex;
- Antigravity;
- OpenAI API;
- Gemini API;
- Anthropic API.

Claude Code and Ollama are visible in local setup but do not yet have equivalent
complete V7 package/execution coverage.

### Safe inventory and AX execution UX

The Workspace reports credential-free Worker inventory and Cloud stores it in
`workspace_worker_inventory`.

Conclave AX reads the owner-scoped V7 inventory and no longer exposes normal
Cloud-side Worker creation/binding setup.

## Remaining architecture gaps

### 1. Hybrid V7 + V6 scheduler

`apps/cloud/src/v5-scheduler.ts` currently queries both:

~~~text
workspace_worker_inventory
~~~

and the legacy V6 candidate graph:

~~~text
configured_workers
worker_workspace_bindings
workspace_worker_credentials
~~~

and merges the results.

This preserves migration compatibility, but it means V7 is not yet the sole
execution architecture.

**Required completion:** make V7 Worker inventory + Cloud scheduling state +
grants/policies sufficient for candidate selection, prove that path end to end,
then remove V6 candidate resolution.

### 2. Missing independent remote scheduling state

For V7 rows the current scheduler effectively derives scheduling availability
from local Worker readiness.

V7 requires independent Cloud-owned operational state:

~~~text
enabled
disabled
draining
~~~

This state may narrow local capability but can never make an unready Worker
ready or broaden local permissions.

**Required completion:** persistence + API + AX controls + scheduler semantics +
audit for enable/disable/drain.

### 3. Legacy V6 Worker API remains

The Cloud router still exposes V6 configured Worker operations including:
- Cloud Worker creation;
- Worker update/revoke;
- Worker <-> Workspace binding CRUD;
- per-binding setup/reauthentication;
- per-binding credential operations.

These are no longer part of the normal AX UX, but they remain live backend
architecture.

**Required completion:** retire them after real V7 execution acceptance and
remove the corresponding runtime dependencies/tests.

### 4. Legacy V6 persistence remains

The schema still contains:
- `configured_workers`;
- `worker_workspace_bindings`;
- `workspace_worker_credentials`.

The V7 projection lives separately in `workspace_worker_inventory`.

**Required completion:** use a forward migration to remove obsolete tables only
after no production code depends on them. Do not rewrite already-applied
production migrations.

### 5. Production adapter/release trust

`WorkerTrustPolicy` currently verifies release/package signatures with
HMAC-SHA256 shared secrets.

That is suitable for development fixtures but not public desktop distribution,
because a verifier holding the shared signing secret can also produce valid
signatures.

**Release requirement:**
- asymmetric signing, recommended Ed25519;
- private key only in release infrastructure;
- public verification key(s) trusted by Workspace;
- key IDs;
- rotation and revocation;
- manifest + package digest binding retained.

The same principle should be applied to Workspace application update metadata.

This remains a **V7 production release gate**.

### 6. First-party adapter release workflow

Cloud catalog/storage and package publication primitives exist, but there is no
repeatable first-party CI release workflow that builds, tests, signs, publishes,
downloads and verifies adapters.

**Required completion:** add a dedicated adapter release workflow with
development/beta/stable and revocation procedures.

### 7. Claude Code and Ollama are only partially supported

The local Add Worker catalog exposes both.

However:
- Claude Code does not yet have the complete first-party V7 adapter package and
  local auth lifecycle equivalent to Codex/Antigravity;
- Ollama lacks the complete V7 adapter package, endpoint reachability/model
  discovery and execution coverage.

A production catalog should not advertise a Worker Type as supported unless it
can become Ready and execute.

### 8. Inventory reconciliation acceptance

Revision checks and tombstones exist, but authoritative snapshot behavior still
needs explicit reconnect/omission acceptance.

Verify:
- omitted Worker reconciliation;
- reconnect;
- stale/equal revision;
- re-pairing;
- cross-Workspace Worker ID conflict.

### 9. V7 solo acceptance is schema-oriented, not behavioral E2E

The current `apps/cloud/test/v7-solo-acceptance.test.ts` directly inserts:
- V7 Worker inventory;
- Project/grant/workstream state;
- completed Worker assignment.

It does not exercise:
- live inventory synchronization;
- actual scheduler selection;
- Workspace Gateway dispatch;
- local Worker registry resolution;
- V7 adapter child process;
- result return.

Keep the test as schema/lifecycle coverage, but add a true integration
acceptance harness for the complete product path.

### 10. Background desktop UX

Closing the main macOS window no longer has to terminate the runtime, but a real
menu-bar/tray product surface is still missing.

Required maturity:
- status;
- current work;
- pause/resume;
- drain;
- reopen;
- diagnostics/logs;
- quit behavior with active assignments.

### 11. Workspace update integration

The update controller already includes useful release discovery, download,
verification, staging, health and rollback primitives.

Remaining issues include:
- production native `.app` replacement/restart flow;
- active-assignment drain behavior;
- consistent update trust;
- using the build-injected Workspace version instead of a hard-coded runtime
  `0.1.0` value.

### 12. Adapter protocol documentation

The implemented initial V7 protocol includes:

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

Architecture text also mentions request-input where supported, but a structured
interactive request/response pair is not currently part of the V7 schema.

Treat interactive input as deferred until a supported adapter requires it, or
add it through an explicit versioned protocol extension.

## Recommended completion sequence

Use the dedicated
[Architecture v7 completion plan](../roadmaps/ARCHITECTURE_V7_COMPLETION.md).

The short sequence is:

1. V7 scheduling state + complete V7 Cloud candidate model;
2. real V7 end-to-end integration harness;
3. remove V6 scheduler/API/persistence compatibility;
4. asymmetric adapter/update trust;
5. automated first-party adapter releases;
6. complete Claude Code/Ollama and live provider acceptance;
7. failure/security/reconciliation hardening;
8. macOS menu-bar/update/diagnostics maturity;
9. final documentation convergence and V7 baseline declaration.

The E2E harness intentionally comes before destructive V6 cleanup.

## Definition of V7 complete

V7 can be considered the implemented baseline when:

1. a new user creates a Workspace in Conclave AX;
2. installs the macOS Conclave Workspace build;
3. pairs with the one-time code;
4. AX reports the real machine/runtime state;
5. the user creates/authenticates a Worker only in Workspace;
6. the Worker appears automatically in AX;
7. Cloud scheduling state can enable/disable/drain it independently of local
   readiness;
8. Project/Workstream policy can select it;
9. scheduler dispatches it without V6 binding dependency;
10. Workspace resolves the local Worker and verified adapter;
11. adapter executes in the ID-only Workstream directory;
12. result reaches Cloud/AX;
13. no provider secret enters Cloud;
14. legacy V6 Worker bindings/APIs are not required by the current execution
   architecture;
15. production adapter verification uses public-key trust;
16. first-party production Worker Types have signed releases;
17. real failure/security/reconnect acceptance passes;
18. macOS build/sign/notarize and desktop-to-Cloud smoke procedures pass;
19. the runtime reports/updates using the real packaged application version;
20. background desktop lifecycle is production-usable.
