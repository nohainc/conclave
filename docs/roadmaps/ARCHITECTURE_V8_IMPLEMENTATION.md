# Architecture v8 Implementation Plan

**Status:** Accepted implementation target; v8 release declaration pending
**Architecture:** [Architecture v8](../architecture/ARCHITECTURE_V8.md)  
**Decision:** [ADR-018](../decisions/ADR-018-generic-cli-worker-engine-and-tool-profiles.md)  
**Profile contract:** [Tool Profile v1](../specifications/TOOL_PROFILE_V1.md)

## Goal

Converge the local execution layer from one native Worker binary per provider to
one generic isolated CLI Worker Engine driven by signed immutable official Tool
Profiles.

Target:

~~~text
Conclave AX
-> Conclave Cloud
-> Conclave Workspace
-> generic CLI Worker Engine
-> signed Tool Profile
-> provider CLI
~~~

Initial official mappings:

~~~text
ChatGPT -> chatgpt-codex -> codex
Gemini  -> gemini-antigravity -> agy
~~~

Work v1 remains unchanged above logical Worker selection.

## Development principles

1. Do not create a second orchestration system.
2. Preserve logical Worker IDs and Workstream bindings.
3. Keep Workspace provider-agnostic.
4. Keep Engine out of the Flutter process.
5. Keep one Engine process per assignment/probe by default.
6. Profiles are immutable signed releases, not mutable DB settings.
7. Profiles are official/read-only in v8.
8. Never introduce arbitrary shell strings or profile scripting.
9. Profile updates should handle most provider CLI compatibility changes.
10. Engine changes should be rarer and generic.
11. Because the product is still under development, remove obsolete v2
    provider-specific Worker runtime code after v8 acceptance rather than
    maintaining permanent compatibility.
12. Every phase requires tests/evidence before proceeding.

---

# Phase 0 — Freeze v8 terminology and migration boundary

## Objective

Prevent Worker Runtime v2 and v8 concepts from being mixed indefinitely.

Canonical v8 terms:

~~~text
Logical Worker
CLI Worker Engine
Tool Profile Definition
Tool Profile Release
Profile lifecycle/channel
Provider CLI
Local Worker Protocol 4.0
~~~

Deprecated implementation terms after convergence:

~~~text
ChatGPT Worker executable
Gemini Worker executable
provider-specific Worker release
per-provider native Worker package
~~~

Keep:
- Workspace;
- Worker;
- Worker Type;
- Workstream;
- Work Request;
- Work v1 Workflow.

Use the canonical terms above in v8 source, tests, diagnostics, and
documentation. Existing v2/v7 symbols and fixtures may retain their literal
legacy names while they remain migration material, but their test descriptions
and documentation must identify them as historical or migration-only. Do not
use provider-specific Worker executable/package/release terminology for new
v8 contracts.

## Exit

Architecture/docs and new v8 tests use the canonical vocabulary. Existing v2
provider-binary tests and release instructions are explicitly marked
migration-only. No v2 provider binary or release workflow is presented as the
v8 target.

---

# Phase 1 — Extract generic Engine behavior from current Workers

## Objective

Use the currently passing ChatGPT/Gemini Dart Workers as behavior references.

Inventory every provider-specific behavior currently implemented:

### ChatGPT/Codex
- executable discovery paths;
- version parsing;
- `login status`;
- execution arguments;
- prompt-over-stdin;
- JSONL events;
- final message extraction;
- tool-use progress;
- thread/session extraction;
- resume verification;
- model argument;
- environment passthrough;
- error mappings;
- sandbox/approval flags.

### Gemini/Antigravity
- executable discovery;
- version parsing;
- local config/auth checks;
- stream-json input/output;
- timeout argument;
- result extraction;
- conversation ID extraction;
- resume argument;
- model argument;
- environment passthrough;
- progress mappings;
- error mappings;
- sandbox flags.

Classify each behavior as:

~~~text
generic Engine primitive
Profile data
temporary provider-specific code that should disappear
not representable safely -> explicit design decision
~~~

Record the behavior, exact current mapping, v8 owner, and evidence in the
[Worker Engine/Profile migration matrix](WORKER_ENGINE_PROFILE_MIGRATION_MATRIX.md).
The matrix is the handoff contract for Profile and Engine implementation; do not
silently omit behavior that Tool Profile v1 cannot express.

## Exit

The matrix maps every requested ChatGPT/Gemini behavior to a generic Engine
primitive, Profile data, a deletion point for temporary provider code, or a
named design decision. Any design decision needed for Profile parity is carried
as an explicit gate into the phase that freezes the relevant contract.

---

# Phase 2 — Define Tool Profile v1 machine schema

## Objective

Turn the specification into one canonical validator/model.

Resolve the three contract gates in the
[migration matrix](WORKER_ENGINE_PROFILE_MIGRATION_MATRIX.md) before freezing
the validator: the bounded Gemini local-config check, provider timeout versus
Engine cleanup semantics, and deterministic progress-rule precedence. Update
the normative contract/version first if any behavior cannot safely fit Tool
Profile v1 as written.

Implement one schema/model source for:
- identity;
- Engine compatibility;
- provider tool;
- discovery;
- version probe;
- auth/config probe;
- environment;
- execution args;
- stdin;
- output;
- selectors;
- event rules/actions;
- session;
- model;
- timeouts;
- sandbox mapping;
- progress;
- error mapping;
- capabilities;
- compatibility overrides.

Reject unknown fields.

Enforce hard bounds for:
- strings;
- arrays;
- rule counts;
- selector depth;
- regex/pattern IDs;
- environment names;
- argument count;
- compatibility override count.

The canonical source is the strict Zod schema and inferred model in
[`packages/tool-profile/src/index.ts`](../../packages/tool-profile/src/index.ts).
Both initial official Profile fixtures and invalid-section/boundary cases live
under `packages/tool-profile/test/fixtures` and its schema test. The bounded
Gemini config read, independent provider timeout reserve, and first-match rule
order are specified in Tool Profile v1 before validator freeze.

## Exit

Valid/invalid Profile fixtures cover every schema section.

---

# Phase 3 — Create Engine Profile interpreter primitives

## Objective

Build a constrained interpreter, not a scripting language.

Implement:
- closed placeholder expansion;
- structured argument expansion;
- fixed conditional argument forms;
- JSON-object stdin construction;
- raw-text stdin;
- plain/JSON/JSONL output modes;
- bounded selectors;
- event match predicates;
- fixed actions;
- progress message keys;
- terminal success/failure state.

Explicitly prohibit:
- shell;
- dynamic code;
- expressions;
- recursion;
- arbitrary helper commands;
- arbitrary filesystem reads.

The pure interpreter is implemented in
[`packages/tool-profile/src/interpreter.ts`](../../packages/tool-profile/src/interpreter.ts).
It returns argv and stdin values for a separate process boundary; it does not
spawn a process, access the filesystem, or emit raw provider event text as
progress.

## Exit

A pure fixture test can transform a Profile + synthetic provider events into the
same normalized result expected from current Workers.

The executable parity fixtures are
[`interpreter.test.ts`](../../packages/tool-profile/test/interpreter.test.ts)
and the two official Profile fixtures under `packages/tool-profile/test/fixtures`.

---

# Phase 4 — Introduce Local Worker Protocol 4.0

## Objective

Change local runtime identity from provider-specific Worker binary to generic
Engine + Profile.

Initialize request/result must cover:

~~~text
workerTypeId
expectedEngineVersion
profileDefinitionId
profileReleaseVersion
profileDigest
protocolVersion
~~~

Initialize result must include:

~~~text
workerTypeId
engineVersion
profileDefinitionId
profileReleaseVersion
profileSchemaVersion
capabilities
~~~

Probe result adds safe:

~~~text
providerToolName
providerToolVersion
~~~

Keep:
- passive/live probe;
- execute;
- progress;
- result;
- error;
- session policy.

## Exit

Protocol 4.0 golden fixtures and malformed-frame tests pass.

## Phase 4 evidence

The shared protocol package now validates and round-trips Protocol 4.0
initialize, probe, and execute frames. Initialize admission binds the Engine
and immutable Profile release identity; probe fixtures expose only the safe
provider tool name/version. Malformed tests reject Protocol 3.0 initialization,
legacy provider-binary identity fields, unknown fields, and invalid Profile
digests. The migration-only v2 runtime and Workspace release admission still
use the predecessor identity model and must be retired or moved behind the
v2 migration boundary during v8 runtime integration.

---

# Phase 5 — Build the generic CLI Worker Engine executable

## Objective

Create one standalone Dart console app.

Recommended repository shape:

~~~text
engines/
  cli_worker/
    bin/conclave_cli_worker.dart
    lib/
    test/
~~~

Reuse existing shared runtime code where correct:
- process runner;
- streaming;
- locator;
- deadlines;
- cleanup;
- session store;
- logger;
- diagnostics.

Remove product/provider identity assumptions from generic runtime code.

## Exit

Engine starts, validates a test Profile, initializes over Protocol 4.0, and
executes a fixture CLI.

## Phase 5 evidence

`engines/cli_worker` is a standalone Dart console package. Its runtime uses the
shared CLI locator, command/stream runners, environment builder, process
cleanup, and diagnostics while keeping v2 Worker identity out of the Engine
loop. It loads a bounded Profile payload, checks v1 runtime structure and
Engine compatibility, verifies its SHA-256 digest against initialize, and
executes only the Profile-selected CLI with shell execution disabled. The
fixture integration test covers initialize, passive probe, and execution over
Protocol 4.0. Workspace signature verification remains the admission boundary.

---

# Phase 6 — Harden Engine security invariants

## Objective

Make Profile data unable to broaden local execution power.

Engine must hard-code:
- `runInShell=false`;
- provider executable is the only Profile-launched program;
- bounded environment;
- reserved secret-name denylist;
- outer timeout;
- stdout/stderr limits;
- selector/rule bounds;
- Workstream/state directory boundaries;
- allowed sandbox policy enum;
- session-ID validation;
- profile digest/identity checks.

Add adversarial tests:
- shell metacharacters;
- path traversal;
- forbidden executable paths;
- env secret requests;
- selector bombs;
- oversized rules;
- malformed JSONL;
- output floods;
- timeout/cancellation.

## Exit

Security regression suite passes.

## Phase 6 evidence — 2026-10-01

The standalone Engine validates Profile payload size/depth/string bounds,
approved discovery paths, selector/rule limits, sandbox policy names, and
reserved Conclave/cloud environment names. It caps child environment size,
provider I/O, and execution time; provider subprocess launch always disables
shell mode. Session keys and provider session IDs are constrained, and session
files are checked against the Engine state directory boundary.

Regression coverage exercises the official ChatGPT/Gemini Profiles, host/cloud
secret-name rejection, executable and path traversal rejection, selector/rule
bombs, shell metacharacter inertness through Protocol 4.0, malformed JSONL,
stdout floods, timeout cleanup, consumer cancellation, and session-file
traversal/symlink rejection.

Evidence command: `dart analyze && dart test` from `engines/cli_worker` using
the Dart SDK directly; both completed successfully. Workspace host launch and
process-tree cancellation remain integration work for the later release
supervisor wiring phase.

---

# Phase 7 — Implement Profile release domain in Cloud

## Objective

Separate logical Worker catalog from immutable Profile releases.

Add target entities:

~~~text
worker_catalog
tool_profile_definitions
tool_profile_releases
tool_profile_release_audit
tool_profile_channel_pointers (if used)
~~~

Required lifecycle:

~~~text
draft
testing
beta
stable
retired
revoked
~~~

Profile payload is immutable after publication.

Lifecycle/promotion/revocation is audited.

## Development migration

Because project is pre-production, prefer clean v8 tables over preserving old
provider-specific Worker release rows.

## Exit

Cloud can store multiple immutable Profile releases for one definition and
promote/rollback stable selection without modifying payloads.

## Phase 7 evidence

Cloud now has `worker_catalog`, `tool_profile_definitions`,
`tool_profile_releases`, `tool_profile_release_audit`, and
`tool_profile_channel_pointers`. The first logical catalog entries and
ChatGPT/Gemini Tool Profile definitions are seeded. Draft payloads are checked
with the canonical Tool Profile v1 schema; publication verifies the Ed25519
signature and locks the payload/digest/signing identity. Admin endpoints manage
drafts, publication, lifecycle, channel promotion/rollback, and audit reads.
The registry rejects plaintext credential material and reserved host secret
environment names. Workspace resolution returns only a currently selected,
signed, non-revoked profile release.

The pre-production migration clears old native per-provider release rows and
does not copy them into v8 tables. The legacy table schema remains temporarily
for the v2 migration boundary and should be removed with the v2 cleanup gate.
Existing R2 objects are not enumerated by a D1 migration and may remain orphaned
until the artifact cleanup task.

Evidence: Cloud typecheck passed; the Tool Profile schema/lifecycle and route
tests passed (19 tests across five Cloud test files), including multi-release stable rollback, payload
immutability, illegal transition rejection, and audit records.

---

# Phase 8 — Define Profile signing and trust envelope

## Objective

Treat Profile data as executable policy.

Reuse/extend existing release trust:
- Ed25519 signing;
- signing key IDs;
- digest;
- revocation;
- key rotation.

Signed payload covers:
- Profile behavior;
- identity;
- release version;
- logical Worker ID;
- Engine compatibility;
- provider compatibility.

Database lifecycle metadata may be separate but cannot alter signed behavior.

## Exit

Workspace rejects altered Profile payloads even when DB metadata is valid.

---

# Phase 9 — Implement Profile distribution/cache in Workspace

## Objective

Workspace owns trusted local Profile materialization.

Local structure:

~~~text
Profiles/
  chatgpt-codex/
    8/profile.json
    9/profile.json
    release-state.json
  gemini-antigravity/
    ...
~~~

Implement:
- fetch;
- signature/digest verification;
- schema validation;
- immutable local storage;
- active release;
- last-known-good;
- revocation handling;
- bounded retention.

## Exit

Workspace can download and safely cache Profile releases independently of
Engine/Workspace updates.

**Implementation evidence:** Workspace provides the Cloud Profile catalog
client and managed immutable cache in `apps/host/lib/tool_profile_catalog.dart`
and `tool_profile_release_store.dart`. Store tests cover signature/schema
admission, immutable content, active/LKG state, revocation persistence and
fallback, tamper rejection, and bounded retention.

---

# Phase 10 — Implement Profile resolution

## Objective

Select the correct official Profile for the installed provider CLI.

Inputs:
- logical Worker;
- profile definition;
- Engine version;
- provider CLI version;
- release lifecycle/channel;
- revocation;
- local active/LKG state.

Resolution preference:
1. eligible active;
2. compatible current stable;
3. compatible LKG;
4. unavailable.

Unsupported provider version fails closed.

No silent incompatible fallback.

## Exit

Deterministic resolution tests cover old/new/unsupported provider versions.

## Phase 10 implementation evidence

Workspace resolution is implemented in `apps/host/lib/tool_profile_resolver.dart`.
It returns the selected source and release explicitly, checks logical Worker,
definition, channel, Engine range, provider semantic-version range, signature,
and revocation state, and reports unavailable when no eligible candidate
exists. The cache tracks Cloud's current stable version separately from its
active and last-known-good pointers, preserving stable selection through local
rollback and updating lifecycle metadata during signed release promotion.
Deterministic resolver tests cover old and new provider CLI versions, the
current-stable fallback, and an unsupported version failing closed.

---

# Phase 11 — Implement generic provider CLI discovery

## Objective

Move discovery completely into Engine/Profile.

Engine provides generic locator.

Profile supplies:
- executable candidate names;
- approved standard path patterns;
- PATH search permission.

Engine supplies:
- cached verified path;
- OS-generic baseline paths;
- path bounds;
- executable verification.

Do not require users to set Conclave-specific environment variables.

## Exit

Codex and agy are detected through Profiles from normal GUI-started Workspace.

## Phase 11 implementation evidence

The generic locator in `packages/conclave_cli_worker_runtime` searches signed
Profile locations, Engine-owned home/system baseline locations, and bounded
inherited PATH entries when permitted. It rejects path-bearing command names,
relative PATH entries, oversized paths, and stale or malformed cache entries.
The Engine persists one identity-bound executable path per Profile in its
state directory and revalidates that path before reuse. Tests load both
official Profile fixtures, simulate a GUI-style sparse PATH, and detect their
`codex` and `agy` candidates without Conclave-specific environment variables.

The Workspace release supervisor still does not launch the generic Engine;
that process integration remains required to demonstrate the full GUI startup
acceptance path.

---

# Phase 12 — Implement generic version probe and compatibility check

## Objective

Use Profile-defined version command/extraction.

Flow:

~~~text
discover provider CLI
-> run version probe
-> extract semver/version
-> validate supported range
-> resolve eligible Profile release
~~~

Handle bootstrap carefully:
- Profile definition may need a minimal discovery/version contract available
  before final release resolution;
- or stable release candidates may be evaluated in deterministic order.

Do not create a circular dependency between knowing the version and choosing
the Profile.

## Exit

Both Codex and agy resolve correct Profile release from actual installed version.

## Phase 12 implementation evidence

The Engine runs the selected Profile's bounded version arguments with its
declared output stream and timeout, extracts only valid SemVer, and returns the
observed version even when that bootstrap Profile's supported range rejects
it. Workspace now exposes an Engine-compatible bootstrap Profile selection;
the observed version is then passed through normal compatibility resolution,
which can select a compatible stable/LKG release or fail closed. The shared
Tool Profile v1 comparator now applies full prerelease ordering in both Engine
checks and Workspace resolution. Tests cover extracted probe versions, rejected
version ranges, bootstrap without assumed provider compatibility, and SemVer
prerelease boundaries.

On this development host, `agy --version` reports `1.2.14`, which is within the
official Profile fixture range `1.0.0` to `2.0.0`. `codex --version` reports
`0.158.0`, below the fixture's minimum `0.176.0`; it therefore fails closed and
does not resolve to a Profile on this host. The range remains unchanged pending
provider compatibility evidence or a supported Codex CLI installation. The
Workspace still lacks generic Engine launch wiring, so end-to-end GUI
resolution remains pending that integration.

---

# Phase 13 — Implement generic passive probe

## Objective

Move provider readiness into Profile-driven checks.

Support:
- provider executable version;
- auth/status command;
- local config file existence only if Engine explicitly supports bounded
  provider-state checks;
- exit-code success;
- safe issue-code mapping.

Passive probe must never send a model request.

## Exit

ChatGPT/Gemini readiness matches current passing Dart Worker behavior.

---

# Phase 14 — Implement generic live probe

## Objective

Run controlled minimal provider request through normal Profile execution.

Conclave controls:
- prompt;
- expected final text;
- timeout ceiling.

Profile controls only provider transport/parsing.

Testing a disabled Worker remains allowed and does not enable it.

## Exit

Real ChatGPT and Gemini Test buttons pass through generic Engine + Profiles.

---

# Phase 15 — Port ChatGPT/Codex behavior into Profile

## Objective

Create initial official `chatgpt-codex` Profile release reproducing the current
ChatGPT Dart Worker.

Required coverage:
- discovery;
- version;
- login status;
- environment;
- command args;
- stdin prompt;
- JSONL parsing;
- final agent message;
- progress/tool-use;
- model option;
- ephemeral/stateless mode;
- durable session start/resume;
- session identity verification;
- sandbox/approval mapping;
- error mapping.

Build fixture corpus from real/synthetic current Codex events.

## Exit

Generic Engine + Profile passes all current ChatGPT Worker unit/acceptance tests.

---

# Phase 16 — Port Gemini/Antigravity behavior into Profile

## Objective

Create initial official `gemini-antigravity` Profile release.

Required coverage:
- discovery;
- version;
- local config/auth readiness;
- environment;
- stream-json input;
- stream-json output;
- timeout argument;
- result status/response;
- progress step updates;
- conversation ID start/resume;
- model option;
- sandbox policy;
- error mapping.

## Exit

Generic Engine + Profile passes all current Gemini Worker unit/acceptance tests.

---

# Phase 17 — Session store convergence

## Objective

Make Engine session storage provider-neutral.

Session key:

~~~text
logical Conclave sessionKey
-> provider session ID
~~~

The Engine partitions local mappings by logical Worker, Profile definition,
provider tool identity, and logical `sessionKey`. Each Profile Release declares
its `session.formatId` and compatible prior formats. An incompatible format is
treated as an empty session; successful durable execution replaces the mapping
with the new provider session ID.

State should be partitioned by:
- logical Worker;
- Profile definition;
- provider tool identity where needed.

Profile describes extraction/resume; Engine enforces continuity.

Handle Profile release changes:
- reuse session only when new release declares session-format compatibility;
- otherwise start a new provider session safely.

## Exit

Durable Direct and multi-step Work v1 sessions continue through generic Engine.

---

# Phase 18 — Engine/profile diagnostics

## Objective

Make the new layers visible in diagnostics without complicating normal UX.

Record:

~~~text
Workspace version
Engine version
logical Worker
Profile definition/release
provider tool/version
profile resolution source
probe stage
assignment/run IDs
stable error code
duration
~~~

Advanced UI only:

~~~text
Engine: 1.x
Integration: chatgpt-codex@N
Provider tool: Codex X
~~~

Never expose raw provider credentials/profile secrets.

## Exit

A failure can be attributed to Engine vs Profile vs provider tool.

---

# Phase 19 — Profile candidate activation transaction

## Objective

Prevent bad stable Profile updates from replacing a working integration.

Candidate flow:

~~~text
download
-> trust/schema validation
-> Engine compatibility
-> provider version compatibility
-> candidate Engine initialize
-> passive probe
-> activate
-> previous becomes LKG
~~~

Do not automatically spend model quota during routine Profile update.

## Exit

Broken candidate keeps prior Profile active.

---

# Phase 20 — Profile rollback/revocation

## Objective

Support fast operational recovery.

Rollback:
- select prior trusted compatible release;
- initialize/passive probe;
- atomically switch.

Revocation:
- immediately make release ineligible;
- if active, resolve another eligible release;
- if none, mark Worker needs attention.

Provider auth/quota/outage is not a reason to rollback Profile.

## Exit

Profile regression can be recovered without Workspace/Engine binary update.

---

# Phase 21 — Testing/Beta/Stable channels

## Objective

Use database-managed lifecycle safely.

Testing Workspaces/users can receive `testing` release.

Beta is optional wider validation.

Stable is normal production.

Channel selection should be Conclave-controlled in v8; normal users do not
choose arbitrary Profile channels.

Internal/development tooling may opt a Workspace into testing/beta.

## Exit

A new Profile release can be validated against real machines before stable
promotion.

Implementation evidence (2026-10-01): Cloud now defaults each Workspace to
`stable` and stores a constrained per-Workspace channel override. Platform
administrators can opt internal Workspaces into `testing` or `beta` through the
authenticated channel-management API. The Profile catalog endpoint derives the
channel from the authenticated runtime identity and rejects caller-selected
channels. Workspace validates and passively probes releases from that channel
before activation; explicit Worker Test remains the live-provider acceptance
step. No Profile payload or logical Worker identity changes when a release is
promoted across channels.

---

# Phase 22 — Profile fixture harness

## Objective

Make Profile changes cheap to validate.

Fixture structure conceptually:

~~~text
profiles/chatgpt-codex/
  fixtures/
    version/
    auth/
    execute-success/
    execute-tool-use/
    execute-error/
    session-start/
    session-resume/
~~~

Harness runs Profile interpreter against fixture streams and verifies:
- version extraction;
- readiness;
- result;
- progress;
- errors;
- sessions.

## Exit

Profile release CI can run without provider quota.

Implementation evidence (2026-10-01): `packages/tool-profile/test/fixtures/profiles`
contains versioned manifests and synthetic version, readiness, success, tool-use,
error, session-start, session-resume, and session-mismatch evidence for both
official Profiles. `pnpm --filter @conclave/tool-profile test:fixtures` runs the
pure interpreter harness without starting provider processes or making network
requests. Expected normalized readiness and execution results are declared in the
manifests, so a Profile behavior change is reviewed against explicit fixtures.

---

# Phase 23 — Real Profile acceptance pipeline

## Objective

Require real provider evidence before official stable promotion.

For each first-party Profile:
- passive probe;
- live probe;
- representative assignment;
- Workstream write where applicable;
- durable session start/resume;
- cancellation;
- timeout.

This suite is opt-in/controlled because it uses provider allowance.

## Exit

Testing Profile release has real acceptance evidence.

Implementation evidence (2026-10-01): the host acceptance test
`apps/host/test/tool_profile_real_acceptance_test.dart` runs the generic Engine
against the checked-in official Profiles and installed provider CLIs. It is
skipped unless `CONCLAVE_TEST_REAL_PROFILE_CHATGPT=1` or
`CONCLAVE_TEST_REAL_PROFILE_GEMINI=1` is explicitly set, and it requires
`CONCLAVE_PROFILE_ACCEPTANCE_EVIDENCE_DIR` before starting provider work. It
records a digest-bound JSON artifact covering passive/live probes, a
representative Workstream file write, durable start/resume, timeout, and
process-tree cancellation. Stable Cloud promotion now validates that artifact
against the immutable release digest, logical Worker, Engine/provider version
ranges, required scenarios, and a 90-day freshness limit, then stores it in the
immutable acceptance evidence table. The actual provider run remains an
operator-controlled action and was not run as part of ordinary CI.

---

# Phase 24 — Logical Worker catalog in Cloud

## Objective

Decouple product-visible Worker additions from native application releases.

Initial catalog:

~~~text
chatgpt -> chatgpt-codex
gemini  -> gemini-antigravity
~~~

Catalog includes:
- display name;
- profile definition;
- engine family;
- visibility/release stage;
- product capabilities metadata.

Normal Workspace syncs approved catalog entries and renders logical Workers.

Do not permit arbitrary user-created Worker catalog entries in v8.

## Exit

A future approved CLI Worker can be added through catalog + Profile release
without Workspace rebuild when Engine supports it.

### Implementation evidence

- Cloud migration 0047 adds bounded Engine family, visibility, release stage,
  product capabilities, and catalog ordering metadata.
- Workspace fetches and caches the channel-filtered Cloud catalog, resolves
  Profile definitions by logical Worker ID, and renders rows from catalog data.
- Catalog visibility is independent from Profile release availability; a
  missing, incompatible, or revoked release leaves the Worker visible but not
  runnable.
- Catalog creation is limited to platform administrators and creates the
  Worker mapping plus Profile definition atomically.
- Workspace still requires signed Profile release verification and a passive
  candidate probe before local activation.

---

# Phase 25 — Preserve current Workspace Worker UX

## Objective

Do not expose implementation complexity.

Keep:
- one row per logical Worker;
- enable/disable;
- readiness;
- provider CLI version;
- Test;
- additional local settings already justified.

Do not add:
- JSON editor;
- Profile picker;
- arbitrary executable field;
- Profile creation;
- normal user lifecycle channel selection.

### Implementation evidence

The catalog-backed Workers surface keeps one row per logical Worker with the
existing setup, readiness, provider CLI version, Test, and enable/disable
controls. Capability and Profile details remain out of the normal Worker row;
Engine/Profile version information remains in Advanced Diagnostics.

Advanced Diagnostics may show Engine/Profile versions.

## Exit

Existing users experience the runtime migration with minimal UI change.

---

# Phase 26 — Safe Worker inventory v8

## Objective

Synchronize enough evidence to Cloud for scheduling/support.

Add/rename safe fields:

~~~text
engine_version
profile_definition_id
profile_release_version
provider_tool_name
provider_tool_version
~~~

Preserve:
- activation;
- readiness;
- capabilities;
- concurrency;
- logical worker type.

Remove provider-specific native Worker runtime version semantics once migrated.

## Exit

**Implementation evidence:** Workspace inventory now carries Engine version,
Profile definition/release, provider tool name/version, capabilities, readiness,
activation, and concurrency. Cloud persists and returns only these bounded
fields, and scheduling requires Engine plus Profile release evidence. Migration
`0048_safe_worker_inventory_v8.sql` removes the obsolete provider-native
`worker_runtime_version` column and renames the assignment version column.
Assignment/run history displays the execution evidence frozen at dispatch,
independent of current inventory/Profile promotion.

Cloud can diagnose/schedule v8 Workers without local paths or secrets.

---

# Phase 27 — Assignment snapshot/evidence v8

## Objective

Record which runtime configuration actually performed work.

Assignment/run evidence should capture:
- logical Worker;
- Engine version;
- Profile definition/release;
- provider tool version;
- model when explicit.

A Profile promotion during a running assignment must not change that assignment.

## Exit

**Implementation evidence:** Dispatch stores the selected logical Worker,
Engine version, Profile definition/release, provider tool identity/version, and
explicit model in the assignment permission snapshot; the assignment row also
stores its logical Worker, Engine version, and model. Workspace dispatch uses
that same frozen selection. Work Step results and run-history APIs expose the
stored assignment evidence and do not substitute current inventory for an
assigned run. The runtime acceptance test promotes the inventory values after
execution and verifies the assignment snapshot still contains its original
selection. Historical pre-v8 assignments without a frozen Profile identity
do not mislabel their former Worker package version as a CLI Worker Engine
version.

Historical runs remain explainable after Profile updates.

---

# Phase 28 — Work v1 regression acceptance

## Objective

Prove v8 is transparent above the Worker boundary.

Run real:
- Direct;
- Research;
- Plan & Implement;
- Implement & Verify;
- Full Cycle.

Verify Worker bindings still target logical Workers only.

Verify:
- read/write semantics;
- independent Verify session;
- step handoffs;
- cancellation;
- browser reconnect/history.

## Exit

**Implementation evidence:** The Cloud acceptance harness runs each immutable
Work v1 built-in definition—Direct, Research, Plan & Implement, Implement &
Verify, and Full Cycle—through `ConclaveRunWorkflow` and checks logical binding
IDs, step order, read/write policy, upstream result handoffs, and cancellation
before downstream dispatch. Verify and Implement session keys are separately
tested. Workspace/Engine assignment acceptance remains covered by the v8
runtime acceptance matrix; Cloud Gateway replay and AX Work history reconnect
refresh are covered independently. Provider responses in the workflow-runner
matrix are fixtures, so this regression gate does not spend provider quota.

Work v1 behavior is unchanged after Engine/Profile migration.

---

# Phase 29 — Engine release management

## Objective

Keep Engine update model simpler than old per-provider Worker releases.

Initial approach:
- Workspace release bundles a known-good Engine;
- Workspace materializes Engine into managed runtime directory;
- Engine version is independently observable.

Optional later:
- separately signed Engine releases;
- Engine active/LKG rollback independent of Workspace.

Do not block v8 on independent Engine OTA if bundled Engine updates are enough.

## Exit

Engine has a clear trusted lifecycle and rollback strategy.

## Phase 29 implementation evidence

- The signed/notarized Workspace release is the initial Engine trust boundary;
  no independent Cloud Engine catalog or mutable Engine lifecycle is required.
- Workspace materializes the bounded bundled executable beneath
  `Engines/cli_worker/<version>-<sha256>/`, rehashes cached bytes at startup,
  and repairs altered cache contents from the bundled asset.
- Protocol 4.0 initialization and diagnostics expose the Engine version
  independently from Workspace and Profile versions.
- Engine rollback is a whole-Workspace-release rollback. Until the native app
  update transaction passes end-to-end health and rollback acceptance, restore
  the previous verified signed/notarized Workspace archive manually.
- A separately signed Engine OTA with its own active/LKG state remains optional
  follow-on work, not a v8 prerequisite.
- Focused loader tests cover version/digest materialization, cache repair, and
  fail-closed behavior when the release asset is absent.

---

# Phase 30 — Database convergence

## Objective

Aggressively remove obsolete pre-production release/runtime schemas.

After v8 acceptance:
- remove per-provider native Worker release rows/tables;
- migrate/rebuild Worker inventory to v8 fields;
- add Profile tables;
- update seeds;
- consolidate development migrations where safe;
- ensure clean-room D1 bootstrap produces only current v8 runtime structures.

Keep historical Work/Run records only where needed by active test environments.

## Exit

A clean database has no requirement for provider-specific Worker binaries.

## Phase 30 implementation evidence

- Forward migration `0049_remove_native_worker_release_catalog.sql` drops the
  obsolete `worker_releases` table. The earlier v7 adapter table is already
  removed by the migration chain; neither is present after a clean v8 bootstrap.
- Migrations `0044`–`0048` provide the v8 logical Worker catalog, immutable
  Tool Profile release domain, channel pointers, audit trail, and safe v8
  Worker/assignment evidence. Clean-room checks now apply the full ordered
  migration directory and assert the v8 fields and release tables.
- The optional `seed/v6-development.sql` contains only logical Worker and
  Profile Definition identities. It seeds no Profiles, Workspaces, credentials,
  assignments, or historical Work/Run data.
- D1 migration history remains forward-only for any initialized development
  database; historical migration files are retained, while the resulting v8
  schema no longer contains native provider Worker release rows/tables.
- Work/Run history and assignment snapshots are not rewritten or dropped.

---

# Phase 31 — Remove provider-specific Worker executables

## Gate

Do not start cleanup until:

~~~text
ChatGPT Engine/Profile real acceptance passes
AND
Gemini Engine/Profile real acceptance passes
AND
Profile activation/rollback passes
AND
Work v1 full-path regression passes
~~~

Then delete:
- `workers/chatgpt` provider-specific executable package;
- `workers/gemini` provider-specific executable package;
- per-provider native release workflows;
- provider-specific binary version selection;
- duplicate provider logic now expressed by Profiles;
- stale v2 compatibility tests/docs.

Retain fixture material useful for Profile tests.

## Exit

Normal first-party execution uses only generic Engine + official Profiles.

---

# Phase 32 — Remove v2 provider-specific release UX/domain

## Objective

Converge product/runtime terminology.

Replace:
- per-Worker binary update/downgrade UI;
- provider Worker release IDs;
- old Worker executable release catalog.

With:
- Engine version under Advanced;
- automatic official Profile release lifecycle;
- optional Profile release info under Advanced.

Normal user still sees logical Worker + provider CLI version.

## Exit

No normal UX suggests ChatGPT/Gemini are separate Conclave binaries.

## Phase 32 implementation evidence

- Workspace Advanced Diagnostics now presents Engine version, official Tool
  Profile identity/status, and provider CLI/version. It no longer shows native
  Worker package version, publisher, signing key, signature status, or package
  channel.
- AX Workspace inventory details use Engine, Profile integration, and provider
  CLI fields from the v8 safe inventory projection; the old Adapter label is
  removed. Normal Worker cards continue to show the logical Worker and local
  provider CLI/version.
- Phase 31's real ChatGPT and Gemini acceptance gate is still outstanding, so
  provider-specific executables, update stores, and compatibility code remain
  intact. The UI convergence does not perform that gated removal.

---

# Phase 33 — Docs and API convergence

Update:
- README;
- root Architecture;
- root Roadmap;
- Technology Stack;
- Protocol Boundaries;
- Workspace release operations;
- release trust;
- first-party Worker catalog;
- Worker testing;
- v7/v2 docs status;
- application boundaries.

Mark:
- Architecture v7 historical baseline;
- Worker Runtime v2 process-boundary predecessor;
- ADR-017 superseded in implementation by ADR-018.

## Exit

A new developer reads v8 first and cannot reasonably implement another
provider-specific Worker binary for a normal CLI.

---

# Phase 34 — Add a third-CLI scalability proof

## Objective

Prove the primary v8 value.

Add one development/testing CLI integration using only:
- logical Worker catalog entry;
- Tool Profile definition/release;
- fixtures;
- acceptance tests.

Do not add provider-specific Workspace/Engine code unless Profile v1 genuinely
cannot express a generic requirement.

This may use a fixture/test CLI rather than a production provider.

## Exit

Third integration is added without compiling a new provider Worker executable.

---

# Phase 35 — Profile schema evolution gate

## Objective

Establish discipline before Profile v2.

When a future CLI requests unsupported behavior:
1. document the missing primitive;
2. prove it is generic across integrations or clearly justify specialized
   handling;
3. update threat model;
4. create Profile schema v2 only when needed;
5. retain strict backwards validation.

Never add arbitrary expression/script support as convenience.

## Exit

Tool Profile remains a constrained data format.

---

# Phase 36 — Architecture v8 release declaration

## Gate status

**Declaration:** Withheld. Architecture v8 is the accepted implementation
target; current production behavior is not declared to use Profiles end to end.
The phase is complete only when every gate below has release evidence. Passing
unit/fixture tests or having implementation code is not, by itself, evidence
that a real provider rollout or production operation passed.

| Release gate | Current evidence/status |
| --- | --- |
| Generic Engine is the sole first-party CLI runtime | **Open.** `workers/chatgpt` and `workers/gemini` provider-specific packages remain in the repository. |
| ChatGPT and Gemini official Profiles are stable | **Not evidenced.** Official Profile fixtures exist; this repository review found no recorded stable promotion evidence for both first-party releases. |
| Real provider acceptance passes | **Open.** The opt-in suite in `apps/host/test/tool_profile_real_acceptance_test.dart` skips unless provider-specific opt-in variables are set and requires retained evidence output. No completed run evidence is recorded here. |
| Profile lifecycle, promotion, and rollback are operational | **Partially implemented; operational acceptance open.** Domain/store tests cover lifecycle and rollback behavior, but a release record proving the end-to-end operational gate is not recorded. |
| Work v1 full-path acceptance passes | **Partially evidenced.** The Phase 28 Cloud regression uses fixture provider responses and exercises all built-in Workflows. Full-path acceptance through the real generic Engine/provider path remains open. |
| v2 provider-specific binaries are removed | **Open.** Both provider package directories and their executables remain. Phase 31 cleanup is gated on real acceptance. |
| Clean database bootstrap matches v8 | **Implementation evidence recorded in Phase 30.** Re-run and attach the clean-room acceptance result to the release record before declaration. |
| Docs and release operations are converged | **Open.** Migration-only v2 release workflows/tooling remain while Phase 31 cleanup is gated. |
| Failure/security acceptance passes | **Partially evidenced.** Engine adversarial regression coverage is recorded in Phase 6; the combined release-level failure/security acceptance result is not recorded. |

Keep this declaration withheld while any gate is open or lacks its required
release evidence. When all gates pass, replace this status with the release
version/date and link the immutable acceptance evidence for each row. Do not
infer completion from the implementation phase numbers or from a passing
fixture suite.

## Objective

Declare v8 implemented only when:

- generic Engine is the sole first-party CLI runtime;
- ChatGPT/Gemini official Profiles are stable;
- real provider acceptance passes;
- Profile lifecycle/promotion/rollback is operational;
- Work v1 full-path acceptance passes;
- v2 provider-specific binaries are removed;
- clean database bootstrap matches v8;
- docs and release operations are converged;
- failure/security acceptance passes.

Until then, v8 is the accepted implementation target, not a claim that current
production behavior already uses Profiles.

---

# Recommended PR sequence for AI development

Do not implement all phases in one PR.

### PR 1 — v8 contracts
- Profile schema/model;
- Protocol 4.0 models;
- migration matrix from current ChatGPT/Gemini behavior;
- no runtime replacement yet.

### PR 2 — generic Profile interpreter
- placeholders;
- structured arguments;
- JSON input;
- selectors/events/actions;
- validation/security tests.

### PR 3 — generic CLI Worker Engine
- standalone Dart executable;
- protocol 4.0;
- fixture CLI;
- process/security hardening.

### PR 4 — Profile Cloud domain/trust
- D1 Profile tables;
- lifecycle;
- signing;
- API/read models;
- audit.

### PR 5 — Workspace Profile cache/resolver
- fetch/verify/cache;
- active/LKG;
- compatibility resolution;
- candidate probe/activation.

### PR 6 — ChatGPT/Codex Profile
- fixtures;
- passive/live probe;
- execute/session;
- real acceptance.

### PR 7 — Gemini/Antigravity Profile
- fixtures;
- passive/live probe;
- execute/session;
- real acceptance.

### PR 8 — Inventory/diagnostics/UX convergence
- Engine/Profile safe fields;
- Advanced diagnostics;
- preserve current Worker UX.

### PR 9 — Work v1 full regression
- all built-in Workflows through generic Engine;
- cancellation/reconnect/failure tests.

### PR 10 — Profile release channels and rollback
- testing/beta/stable;
- promotion;
- rollback/revocation;
- release automation.

### PR 11 — Engine release lifecycle
- bundled baseline;
- managed runtime materialization;
- rollback if needed.

### PR 12 — aggressive v2 cleanup
- delete provider-specific Worker binaries;
- remove per-provider native release system;
- DB migration consolidation;
- stale code/tests/docs cleanup.

### PR 13 — third-CLI proof
- profile-only new integration;
- no provider-specific Workspace/Engine code.

### PR 14 — v8 release gate
- clean-room acceptance;
- security/recovery;
- docs convergence;
- declare implemented baseline only after evidence.

---

# AI task completion rules

For each implementation PR, the assigned AI model should:

1. read ADR-018, Architecture v8, Tool Profile v1, and this roadmap;
2. inspect current code before changing it;
3. preserve logical ChatGPT/Gemini IDs and Work v1 semantics;
4. avoid introducing compatibility layers unless a current supported path
   actually requires them;
5. add/update unit tests before claiming the phase complete;
6. include exact commands/tests run and results;
7. identify any phase requirement intentionally deferred;
8. avoid implementing later phases opportunistically unless required for a
   clean interface;
9. prefer deletion over leaving duplicate v2/v8 runtime paths after the
   convergence gate;
10. never weaken Profile/Engine security boundaries to make a provider easier
    to integrate.

## Final target

~~~text
                         CONCLAVE AX
                             |
                             v
                       CONCLAVE CLOUD
                    Work + Profile Registry
                             |
                             v
                    CONCLAVE WORKSPACE
                             |
                             v
                    CLI WORKER ENGINE
                     one native binary
                             |
                  signed official Profile
                             |
                             v
                       provider CLI
~~~

The success criterion is operational:

> A normal provider CLI compatibility change should usually be fixed, tested,
> promoted, rolled back, or revoked as a Tool Profile release without rebuilding
> Conclave Workspace or compiling a provider-specific Worker binary.

---

# Phase 34 — Third-CLI scalability proof

**Status:** Complete as a development/testing integration; not an official
user-facing Worker.

The optional development seed maps the testing-only `fixture-worker` Logical
Worker to the `fixture-cli` Tool Profile Definition. Its v1 release payload and
version/readiness/success/error fixtures live under
`packages/tool-profile/test/fixtures/`. Workspace acceptance signs that
payload with ephemeral test keys, syncs the logical catalog entry, admits the
release, and runs passive/live probes through the generic CLI Worker Engine.
The Engine acceptance test compiles only the fixture **provider CLI** into a
temporary test directory; it does not compile a Conclave Worker executable.

No provider-specific Workspace or Engine code was added. The fixture is
testing-channel only and does not enter the stable catalog.

Evidence collected:

- `node_modules/.bin/vitest run packages/tool-profile/test/profile-fixture-harness.test.ts apps/cloud/test/v8-schema-clean-room-acceptance.test.ts` — 40 tests passed.
- Dart test `engines/cli_worker/test/engine_e2e_test.dart` — 2 tests passed, including Protocol 4.0 probe and execution.
- Dart test `apps/host/test/fixture_cli_profile_acceptance_test.dart` — passed through catalog sync, signed release admission, passive readiness, and live probe.

The normal official catalog, real-provider acceptance gates, and Phase 31
provider-binary cleanup are unchanged by this proof.

---

# Phase 35 — Profile schema evolution gate

**Status:** Complete. Tool Profile v1 remains the only defined Profile schema.

The normative v1 specification and v8 threat model now require a documented
missing primitive, genericity assessment, security review, and separate strict
versioned validation before schema v2 is considered. Unknown fields/versions
continue to fail closed; no script, expression, or permissive compatibility
path is added.

Regression evidence: `packages/tool-profile/test/profile-schema.test.ts`
rejects schema version 2, a script field, and an expression-like placeholder.
The existing fixture suite continues validating official v1 and development
v1 Profiles.
