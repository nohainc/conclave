# Worker Runtime v2 Implementation Plan

**Status:** Implementation in progress — Phases 1–17 have initial implementation; first-party assignment routing remains
**Architecture:** [Worker Runtime v2](../architecture/WORKER_RUNTIME_V2.md)  
**Decision:** [ADR-017](../decisions/ADR-017-standalone-dart-worker-executables.md)  
**Product baseline:** Architecture v7 / ADR-015 ChatGPT + Gemini first-party catalog

## Goal

Replace the legacy Node-backed first-party Worker Package implementation with
independently versioned, signed, native Dart console executables while
aggressively removing unreleased compatibility from the legacy implementation.

Target runtime:

~~~text
Conclave Cloud
-> Conclave Workspace
-> native Dart Worker executable
-> provider CLI
~~~

First-party Workers:

~~~text
ChatGPT Worker -> Codex CLI
Gemini Worker  -> agy
~~~

## Guiding implementation rules

1. Workspace never executes provider commands directly.
2. Worker executable is a console app, not Flutter UI/plugin.
3. User installs no Node/Dart runtime for Workers.
4. Each assignment uses a fresh Worker process by default.
5. Worker/provider process tree remains Workspace-owned.
6. Worker versions are immutable and independently upgradable/rollbackable.
7. Worker state is version-independent.
8. Local Worker Protocol is provider-neutral.
9. Provider secrets never enter Cloud.
10. Development migration may delete obsolete state/schema/code instead of
    carrying compatibility indefinitely.

---

# Phase 0 — Freeze Worker Runtime v2 terminology and scope

## Objective

Prevent another partial migration where legacy Node terminology remains mixed
with the new Worker executable model.

## Rename conceptually

The terms on the left identify legacy names for this migration only. They are
not alternate names for Runtime v2 concepts.

~~~text
adapter package
-> Worker release/package

adapter version
-> Worker runtime version

adapter process
-> Worker process

Local Adapter Protocol
-> Local Worker Protocol
~~~

Internal filenames and symbols may remain temporarily during implementation,
but new Runtime v2 code, tests, APIs, and documentation use Worker terminology.
Legacy adapter names may appear only when identifying those existing symbols or
describing migration/history. Provider tools retain provider-tool terminology.

## Keep unchanged

- Architecture v7;
- Workspace ownership;
- ChatGPT/Gemini product Worker IDs;
- Cloud/Workspace transport;
- Workstream directory model;
- AX-owned usage/model selection;
- Workspace desktop lifecycle.

## Exit

Architecture/docs/tests use one vocabulary for all new Worker Runtime v2 work.

---

# Phase 1 — Create Dart Worker monorepo structure

## Objective

Create the code organization before porting provider logic.

Recommended:

~~~text
packages/
  conclave_worker_protocol/
  conclave_cli_worker_runtime/

workers/
  chatgpt/
  gemini/
~~~

### `conclave_worker_protocol`

Contains:
- Local Worker Protocol 3.0 models;
- frame parser/serializer;
- validators;
- error/issue codes;
- protocol negotiation helpers;
- bounded text/collection limits.

### `conclave_cli_worker_runtime`

Contains:
- CLI discovery;
- environment construction;
- process execution;
- streaming line/event support;
- deadline/cancellation;
- process-tree cleanup helpers where Worker-owned;
- session store;
- logging;
- redaction;
- diagnostic capture.

## Do not

- import Workspace Flutter packages into Worker executables;
- import ChatGPT/Gemini implementation into Workspace;
- create Flutter targets for Workers.

## Exit

A trivial Dart console Worker can compile and exchange an initialize frame with
a Dart protocol test harness.

---

# Phase 2 — Define Local Worker Protocol 3.0

## Objective

Use the runtime rewrite to remove historical adapter-specific wire baggage.

## Required frames

~~~text
initialize.request
initialize.result
probe.request
probe.result
execute.request
progress
result
error
~~~

Optional later:

~~~text
cancel.request
cancel.result
~~~

Workspace remains able to kill the process tree regardless of protocol
cancellation support.

## Initialize contract

Must validate:
- expected product Worker type;
- exact Worker executable version;
- negotiated protocol;
- state schema;
- capabilities.

## Probe contract

Modes:

~~~text
passive
live
~~~

Passive cannot issue a provider model request.

Live may consume provider quota and must be explicit.

Probe returns:
- ready;
- provider tool name/version;
- local-only provider tool path;
- structured checks;
- stable issue code;
- safe bounded diagnostics.

## Execute contract

Must carry:
- assignment ID;
- request ID;
- prompt;
- optional model;
- remaining timeout;
- session policy;
- optional logical session key.

Must not carry:
- provider secret;
- provider session ID;
- arbitrary executable path;
- arbitrary CWD from Cloud.

All frames use strict field allowlists and bounded fields. Diagnostics and
provider-tool paths are local-only; the path is never copied into Cloud
inventory. Passive probe mode must never issue a provider model request. Golden
JSON fixtures live beside the Dart contract tests, and malformed or forbidden
fields must fail validation.

## Exit

Golden protocol fixtures and malformed-frame tests pass in Dart. The current
contract package is `packages/conclave_worker_protocol`.

---

# Phase 3 — Build a Worker SDK reference executable

**Status:** Implemented

## Objective

Prove the generic process/protocol architecture before provider ports.

Create a development-only `echo/test Worker` executable that:

- initializes;
- passively probes Ready;
- live probes without external provider;
- emits progress;
- returns deterministic output;
- supports cancellation/timeout;
- supports a fake durable session;
- logs structured stderr JSONL.

Workspace uses this executable in E2E tests.

## Why

Do not debug Dart protocol, package installation, process supervision, Codex and
agy simultaneously.

## Exit

Workspace -> native Dart Worker -> result works with no Node dependency.

## Phase 3 implementation

The shared Dart runtime now serves Local Worker Protocol 3.0 initialize,
probe, and execute frames. The development-only `workers/test_worker` supplies
fake probes, deterministic execution, progress, timeout behavior, and durable
session state. The Workspace acceptance test compiles it to a native executable
and launches it through Workspace process isolation; cancellation and deadline
coverage terminates the process tree. The executable does not invoke Node, Dart
at runtime, or an external provider.

---

# Phase 4 — Introduce Worker release manifest v2

**Status:** Implemented

## Objective

Replace adapter-centric manifest fields with native Worker release metadata.

Required fields conceptually:

~~~text
workerTypeId
workerVersion
publisher
platform
protocol.min
protocol.max
stateSchema.readMin
stateSchema.readMax
stateSchema.write
capabilities
permissions
executable
releaseChannel
packageDigest
archiveSha256
signingKeyId
signature
~~~

Remove first-party dependencies on:
- Node prerequisite;
- provider executable prerequisite in Workspace;
- provider version command metadata;
- provider auth command metadata;
- provider CLI environment interpretation in Workspace.

Provider specifics stay inside executable.

## Exit

Workspace can verify a native test Worker artifact with no provider knowledge.

The strict v2 manifest schema exists in the TypeScript contract package and
Workspace verifier. The Workspace acceptance test signs a native Test Worker
artifact, validates its platform, protocol, state schema, permissions, archive
hash, package digest, executable path, and Ed25519 signature, then launches the
admitted executable. The sidecar manifest contains no provider executable,
version-command, auth-command, or provider-environment metadata.

---

# Phase 5 — Replace adapter release storage with Worker release storage (complete)

## Objective

Make native platform artifacts first-class.

Because the project is pre-production, prefer a clean table over another
compatibility layer.

Replace conceptually:

~~~text
v7_adapter_releases
~~~

with:

~~~text
worker_releases
~~~

Recommended primary identity:

~~~text
(worker_type_id, version, platform)
~~~

Store:
- release channel;
- protocol range;
- state schema compatibility;
- manifest;
- digest/hash;
- R2 key;
- revocation;
- created time.

## Migration strategy

Development environments may:
- drop old adapter release rows/table;
- recreate release data from the new publish workflow.

Do not write an elaborate adapter->Worker release data migration unless a real
environment needs it.

## Exit

Cloud release API/catalog returns platform-specific native Worker releases.

---

# Phase 6 — Implement immutable local Worker version store (complete)

## Objective

Separate installed Worker executable versions from Worker state.

Recommended local layout:

~~~text
Workers/<type>/
  versions/<version>/
  state/
  logs/
  release-state.json
~~~

Implement:
- staging directory;
- archive extraction validation;
- signature/digest verification;
- immutable install;
- active version pointer;
- last-known-good pointer;
- bounded retention;
- cleanup of orphan staging directories.

Do not overwrite active executable files.

## Exit

Two versions of the test Worker can coexist and Workspace can switch atomically.

---

# Phase 7 — Implement protocol/state compatibility admission (complete)

## Objective

Prevent incompatible Worker activation.

Before launch/activation validate:
- current platform;
- Workspace supported protocol range;
- Worker protocol range;
- Worker state read compatibility;
- requested permissions.

On initialize verify executable identity matches manifest.

## Exit

Tests prove:
- incompatible protocol rejected before assignment;
- wrong Worker Type rejected;
- wrong version rejected;
- incompatible state schema rejected.

---

# Phase 8 — Implement per-Worker update policy (complete)

## Objective

Make version management a product feature.

State:

~~~text
updatePolicy = automatic | notify | pinned
pinnedVersion = optional
activeVersion
lastKnownGoodVersion
~~~

Initial default:

~~~text
notify
~~~

UI supports:
- current Worker version;
- available version;
- Update;
- installed versions;
- Roll back/use previous;
- Pin/unpin under Advanced.

Worker update must not update provider CLI.

## Exit

ChatGPT and Gemini can independently use different Worker release policies.

## Phase 8 implementation

Workspace stores `automatic`, `notify` (the default), or `pinned` policy in
each Worker Type's local release state. The Workers surface shows current and
available versions, installs/updates signed native Worker releases, lists
installed versions, supports rollback, and exposes policy and pin controls
under Advanced. Automatic policy checks the native Worker release catalog
while Workspace is idle. Worker release installation does not invoke provider
CLI installation or update logic.

---

# Phase 9 — Implement Worker candidate validation transaction (complete)

## Objective

Never activate an unverified Worker release.

Candidate flow:

~~~text
download
-> verify
-> install immutable
-> start executable
-> initialize/self-check
-> passive provider probe
-> mark candidate healthy
-> activate atomically
-> mark previous as last-known-good
~~~

If candidate fails:
- terminate it;
- retain current active Worker;
- persist safe failure diagnostic;
- do not change scheduling readiness due solely to candidate failure.

Do not automatically run a quota-consuming live probe during normal update.

## Exit

A broken candidate cannot replace a working active Worker.

## Phase 9 implementation

Native Worker catalog installs remain immutable candidates until Workspace
starts the exact executable and validates its initialize identity and an
explicit passive probe. The candidate process receives only its local state
directory and basic executable-discovery environment; Workspace terminates its
process tree after validation. One atomic release-state write records the
healthy version, activates it, and moves the previous active version to
last-known-good. Failure stores a bounded local diagnostic and leaves active
version and Worker readiness unchanged. Automatic updates do not retry the same
failed catalog version and never run a live probe.

---

# Phase 10 — Implement generic Worker process supervisor convergence

## Objective

Remove remaining adapter-specific assumptions from Workspace process execution.

Workspace owns:
- absolute Worker executable;
- process environment;
- Workstream CWD;
- stdin/stdout protocol;
- stderr log capture;
- timeout;
- cancellation;
- descendant cleanup.

Workspace does not own:
- provider CLI;
- provider process arguments;
- provider parser;
- provider session ID.

Rename/refactor classes where useful:
- `V7AdapterAdmission` -> `WorkerReleaseAdmission`;
- `V7AdapterPackageStore` -> `WorkerReleaseStore`;
- adapter executor/protocol names -> Worker equivalents.

Aggressive rename is preferred because the code is unreleased.

## Exit

The test Worker runs through classes with no adapter/provider naming.

## Implementation status

`WorkerProcessSupervisor` now starts an absolute immutable Worker executable
with no arguments, a locally selected Workstream CWD, an allowlisted generic
environment, and the Worker's independent state directory. It owns protocol
exchange, bounded stdout frames and stderr capture, assignment deadlines,
explicit assignment cancellation, and process-tree termination. Candidate
initialize and passive-probe validation uses the same supervisor. The Dart
reference Worker E2E test exercises this path without adapter or provider
execution classes.

---

# Phase 11 — Implement generic Worker launch environment

## Objective

Eliminate GUI-shell/runtime surprises without leaking parent environment.

Keep:

~~~text
includeParentEnvironment = false
~~~

Workspace provides generic baseline only:
- HOME/USERPROFILE;
- temp;
- locale;
- TLS cert variables;
- deterministic safe PATH;
- Worker state directory;
- Workstream CWD.

Provider-specific environment is interpreted inside the Worker.

The shared Dart CLI runtime may inspect allowed existing environment values as
needed for provider integration, but Workspace must not encode provider
semantics.

## Exit

Native Worker executable starts from Finder/login-item launch without shell
configuration.

## Implementation status

The native Worker supervisor builds an explicit environment with parent
inheritance disabled. It forwards only generic home, temp, locale, TLS,
terminal, and Dart runtime settings; constructs a deduplicated PATH from
absolute parent entries plus stable platform locations; and sets the Worker
state directory. The Workstream CWD is passed as the process working
directory. Provider-specific environment names and values are not interpreted
by Workspace.

---

# Phase 12 — Implement structured Worker logging and diagnostics

## Objective

Make independent Worker releases supportable.

### stdout

Local Worker Protocol only.

### stderr

Structured JSONL operational log where possible.

### Local files

Workspace rotates per-Worker logs:
- size bound;
- count bound;
- no unlimited growth.

### Required context

- Worker Type/version;
- protocol stage;
- assignment/run ID;
- provider tool version if known;
- duration;
- stable error code;
- process exit.

### Redaction

Never log:
- API keys;
- tokens;
- cookies;
- full credential environment;
- prompts/file contents by default.

## Exit

A crashed Worker can produce a copyable local diagnostic report without exposing
secrets.

## Implementation status

Worker stdout remains protocol-only. The Dart Worker logger emits JSONL event
codes with a narrow context allowlist; free-form messages, stack traces,
prompts, file contents, and credential environment values are omitted. The
Workspace stores sanitized Worker events alongside lifecycle records under
each Worker's local log directory, with three 256 KiB files by default. Log
records include release identity, protocol stage, run identity, duration,
stable issue code, process exit, and provider tool version when available.
Incomplete crash-tail records are ignored and rotated before later appends.
The Workers page can copy a bounded local diagnostic report; report contents
are projected through the same safe-field allowlist.

---

# Phase 13 — Port ChatGPT Worker to Dart

## Objective

Reimplement current Codex integration entirely inside the native Dart Worker.

Responsibilities:
- discover Codex;
- cache verified absolute path;
- `--version`;
- passive login/config check;
- live minimal test;
- execute assignment;
- structured event parsing;
- progress;
- final answer extraction;
- stable error mapping;
- sandbox/approval policy;
- durable session support.

Workspace must not contain any Codex command string after this phase.

## CLI discovery

Use shared locator:
1. cached path;
2. bounded PATH;
3. standard locations;
4. platform-specific bounded fallback;
5. not installed.

## Sessions

Keep stateless as default.

For durable sessions:
- store provider session ID in ChatGPT Worker state;
- verify resume actually continues the expected provider session;
- fail safely on mismatch.

## Exit

Real local Codex live acceptance succeeds through the Dart executable.

## Implementation status

The Dart ChatGPT Worker now owns provider-tool discovery and a cached absolute
path, version and passive login checks, explicitly requested live probes,
workspace-write execution policy, JSONL event parsing, safe progress, final
answer extraction, stable protocol failures, and version-independent durable
session state. Durable resume is accepted only when the provider reports the
expected session ID. The executable remains a plain Dart console app and emits
only protocol frames on stdout.

The fake-provider end-to-end test covers initialization, passive readiness,
stateless execution, durable session persistence, and rejection of a mismatched
resumed session. Real local acceptance was run through the compiled Dart
executable using the installed signed-in Codex CLI; initialization, passive
checks, and the minimal live request all succeeded. The legacy Workspace
release catalog still carries its historical package identifier; removal of
that Node-backed release path belongs to the release-store/supervisor
convergence already specified in earlier phases. No provider command arguments
or provider event parsing were added to Workspace.

---

# Phase 14 — Port Gemini Worker to Dart

**Status:** Implemented

## Objective

Reimplement `agy` integration entirely inside the native Dart Worker.

Responsibilities:
- discover `agy`;
- detect version;
- passive local auth/config checks where possible;
- live minimal test;
- headless/streaming execution;
- parse events/result;
- stable error mapping;
- provider sandbox policy;
- durable conversation support.

Workspace must not contain any `agy` command string after this phase.

## Environment

Gemini Worker owns interpretation of Google/Antigravity configuration and any
provider-specific environment values.

Do not require the user to configure Conclave-specific env variables for normal
subscription login.

## Exit

Real local `agy` live acceptance succeeds through the Dart executable.

## Implementation status

The Gemini Worker owns bounded `agy` discovery, verified version and path
caching, passive settings inspection, explicitly requested live probes,
streaming headless execution with the provider sandbox enabled, progress and
result parsing, stable protocol failures, and version-independent durable
conversation state. The CLI has no passive account-status command, so passive
readiness checks local configuration where available and reports account
availability as a warning; a live request verifies actual authentication.
Normal subscription login uses the provider's local credentials and needs no
Conclave-specific setting.

The fake-provider end-to-end test covers initialization, passive readiness,
stale cache fallback, streamed progress/result, durable conversation storage,
and rejection of a mismatched resumed conversation. Real local acceptance was
run through the compiled Dart executable using the installed local CLI; version
detection, configuration inspection, and the minimal live request all
succeeded. Workspace contains no `agy` invocation or provider event parser;
the existing release catalog retains its historical product-package mapping.

---

# Phase 15 — Move session storage fully behind Worker executables

**Status:** Implemented

## Objective

Make session continuity independent from Workspace implementation.

Workspace sends only:

~~~text
sessionPolicy
sessionKey
~~~

Worker stores provider ID locally.

Provider session IDs never:
- enter Cloud;
- enter Workspace inventory;
- become AX-visible.

Session storage remains under version-independent Worker state.

## Exit

Worker executable can be upgraded and continue compatible durable sessions.

## Implementation status

The Workspace supplies the same per-Worker state directory to every installed
version; session files live under `Workers/<type>/state`, alongside but outside
the immutable `versions/<version>` directories. ChatGPT and Gemini Workers use
the shared local session store to map an opaque Conclave key to a provider
conversation ID. Execute frames contain only `sessionPolicy` and `sessionKey`;
strict frame decoding rejects `providerSessionId`. Provider IDs are not part of
Worker release state, Workspace inventory, or Cloud assignment results.

The Workspace E2E test now executes a durable session with Worker 0.1.0,
installs and activates compatible Worker 0.1.1, then confirms a fresh Worker
process resumes the same local session. It also verifies session data remains
outside both immutable release directories and that release state contains no
provider session ID.

---

# Phase 16 — Clean local Worker registry schema

**Status:** Implemented

## Objective

Remove unreleased generic Worker fields that conflict with ADR-015.

Desired local slot state should focus on:

~~~text
workerId
productWorkerTypeId
activationState
localConcurrencyLimit
localPermissions

workerVersionPolicy
activeWorkerVersion

readinessState
readinessIssueCode
lastPassiveProbeAt

lastLiveTestAt
lastLiveTestPassed
lastLiveTestIssueCode
lastLiveTestDetails

providerToolName
providerToolVersion
providerToolPath   // local only

revision/timestamps
~~~

Remove obsolete fields such as:
- user-defined Worker name;
- auth strategy;
- credential reference;
- default model;
- allowed models;
- adapter config;
- adapter version policy/terminology;
- legacy status values used as primary readiness.

Because development migration can be destructive, increment schema and reset
legacy local Worker records if a clean deterministic conversion is not worth
maintaining.

Preserve fixed ChatGPT/Gemini slot identity where practical.

## Exit

Local registry represents ADR-015 directly.

## Implementation status

The Workspace registry now writes schema 17 using product slot IDs and only
activation, local concurrency/permissions, readiness/probe diagnostics,
provider-tool identity/path, and revision/timestamps. Provider-tool paths stay
local. User labels, credential references/status, model defaults/allow-lists,
adapter config/policy, and legacy status are absent from registry records and
backups. Release policy and active Worker version remain in the per-Worker
release-state file, which is the single source of truth for version management.

Opening a valid schema 1–16 registry deterministically retains at most one
ChatGPT and one Gemini record, preserves their selected Worker IDs and safe
permissions/concurrency/activation values, clears the old readiness and
provider-tool diagnostics for a fresh probe, and drops obsolete product types
and duplicate records. Legacy Worker credential references are deleted from
the Workspace secure store, and discarded Worker IDs are passed to local
cleanup. This intentionally does not migrate provider credentials, model
settings, adapter configuration, or obsolete readiness values.

The historical scheduling `status` is now computed from activation and
readiness instead of stored. Startup marks cached Ready slots `not_probed`
until the next passive check; the runtime inventory contract accepts that
explicit readiness state.

---

# Phase 17 — Rebuild Cloud Worker inventory schema cleanly

## Objective

Remove safe-projection columns that are obsolete under the v1 fixed catalog.

Recommended inventory:

~~~text
worker_id
workspace_id
owner_user_id
worker_type_id

activation_state
readiness_state
readiness_issue_code

worker_runtime_version
provider_tool_name
provider_tool_version

capabilities_json
local_concurrency_limit

revision
created_at
updated_at
last_seen_at
~~~

Do not Cloud-store local provider path.

### Development migration

Because the project is not production:
- rebuild the table;
- preserve only rows needed for current test fixtures or reseed;
- update scheduling FK tables in one clean migration;
- delete historical compatibility transformations if no environment requires
  them.

## Exit

Cloud schema no longer exposes obsolete adapter/auth/model fields.

**Implementation:** Migration `0036_worker_inventory_v2.sql` drops and
recreates Cloud inventory and its scheduling/audit foreign-key tables. It
discards development inventory and scheduling rows for reseeding. The new
projection omits provider paths and adapter/auth/model/name/status fields.
Workspace sends authoritative fixed-catalog snapshots; Cloud deletes omitted
slots and cascades their scheduling records. Scheduling requires an enabled,
ready slot with an installed Worker runtime version.

---

# Phase 18 — Rename Cloud/release APIs and domain types

**Status:** Implemented for the native Worker release and inventory surface.

## Objective

Make runtime/API naming match the architecture.

Examples:

~~~text
adapterRelease
-> workerRelease

adapterVersion
-> workerRuntimeVersion

ensureAdapter
-> ensureWorkerRelease

runtimeUnavailable
-> workerRuntimeUnavailable
~~~

Retain provider tool terminology only for Codex/agy-specific Worker
implementation/tests.

## Exit

New API/domain code has no adapter terminology except migration comments.

**Implementation:** Cloud publishes, lists, downloads, revokes, and reports
revocations for Worker releases using Worker terminology. Workspace setup now
ensures native releases through `WorkerReleaseCatalog.ensureWorkerRelease`.
The obsolete core Worker projection was replaced with a typed
`WorkspaceWorkerInventory` contract matching the Cloud safe projection. The
legacy provider-package execution and readiness code remains scheduled for the
provider ports and cleanup phases.

---

# Phase 19 — Integrate Worker runtime version into safe inventory

**Status:** Implemented for Workspace inventory sync, Cloud assignment snapshots,
and Advanced Diagnostics.

## Objective

Allow support/operations to distinguish Worker bugs from provider CLI bugs.

Cloud receives:
- Worker executable version;
- provider tool name/version;
- readiness.

AX/Cloud need not expose all of this prominently.

Workspace Advanced Diagnostics should show:

~~~text
ChatGPT
Worker version: 1.4.2
Codex CLI: 0.x.y
Provider tool path: local-only

Gemini
Worker version: 1.3.0
agy: x.y.z
Provider tool path: local-only
~~~

## Exit

Every failed assignment can be attributed to a concrete Worker release and
provider tool version.

**Implementation:** Workspace inventory reports the admitted Worker runtime
version, provider tool name/version, and readiness to Cloud. The provider path
stays in the local registry and Advanced Diagnostics. Cloud snapshots the
Worker and provider versions into each assignment's existing permission
snapshot and sends the same attribution to Workspace with the assignment.
The native Worker supervisor records both versions with the assignment ID in
its local diagnostic JSONL.

---

# Phase 20 — Update Workers UI for independent Worker versions

**Status:** Implemented in the Workspace Workers screen.

## Objective

Keep normal UI simple while exposing version control.

Worker row:

~~~text
ChatGPT        Ready
Codex CLI 0.x.y
Worker 1.4.2

[Update] [Test] [Enable/Disable]
~~~

No Update button when no newer compatible release exists.

Advanced Worker details:
- installed Worker versions;
- active;
- previous/LKG;
- update policy;
- pin;
- rollback;
- release channel;
- last candidate failure.

Readiness and Disabled badges remain independent.

Test remains available while Disabled.

## Exit

User can update/downgrade a Worker without updating Workspace.

**Implementation:** Worker rows show independent readiness and Disabled
badges, provider CLI version, Worker runtime version, and an Update action only
when a newer compatible release is available and the Worker is not pinned.
Test remains available for disabled Workers. Version activation/rollback,
update policy, pinning, release channel, and bounded last candidate failure
details are under Advanced.

---

# Phase 21 — Build/release CI for native Dart Workers

## Objective

Produce reproducible platform artifacts.

Initial CI matrix:

~~~text
macOS arm64
macOS x64
Linux x64
Linux arm64
Windows x64
~~~

Add Windows ARM64 only when toolchain/provider support is verified.

Each job:
1. restore pinned Dart SDK;
2. run Dart analyze/tests;
3. `dart compile exe`;
4. run protocol self-tests on artifact;
5. package;
6. compute digest/hash;
7. sign manifest/package;
8. publish artifact;
9. write release catalog metadata.

macOS/Windows code signing should be applied where distribution requirements
need it.

## Exit

One release command/workflow publishes matching ChatGPT/Gemini native artifacts.

Implementation: `.github/workflows/release-worker-v2.yml` is the single
manual release workflow. It uses Dart 3.12.2, tests and compiles both Workers
on five native platform runners, verifies each compiled executable with the
Local Worker Protocol initialize harness, then the publisher packages,
hashes, signs, and publishes all ten artifacts. See
`docs/deployment/WORKSPACE_RELEASES.md` for dispatch inputs and required
GitHub secrets/variables.

---

# Phase 22 — Add upgrade/downgrade acceptance suite

**Status:** Implemented

## Objective

Prove version management, not just execution.

Test:

~~~text
install 1.0
activate
execute

install 1.1
candidate validate
activate
execute

rollback 1.0
execute

pin 1.0
publish 1.2
remain 1.0

unpin/update 1.2
execute
~~~

Also test:
- broken signature;
- broken executable;
- protocol mismatch;
- state schema mismatch;
- passive probe failure;
- candidate crash;
- active assignment during update.

## Exit

Rollback is a normal tested workflow.

**Implementation:** The Workspace acceptance test installs and executes Worker
1.0.0, validates and activates 1.1.0, executes it, rolls back and executes
1.0.0, pins 1.0.0 while 1.2.0 is available, then unpins, installs/validates
1.2.0, and executes it. Separate acceptance cases reject a bad signature,
unlaunchable executable, unsupported protocol, incompatible state schema,
failed passive probe, and candidate process crash without changing the active
release. A running assignment defers activation until Workspace terminates the
process and the candidate is validated. The suite exercises compiled native
test Worker processes and the signed local release store.

---

# Phase 23 — Add failure/crash-loop policy

**Status: Implemented (local policy and diagnostics).** Workspace classifies
Worker process crashes, protocol violations, and internal Worker errors
separately from provider/user outcomes. It permits one automatic retry only
when the failed attempt is safe to repeat before execute begins. Three
consecutive Worker-release failures quarantine that version as `Needs
attention`; locally persisted state includes the issue code and a suggested
last-known-good version when one exists. A successful assignment clears the
streak. Provider authentication/tool failures, provider failures (including
quota and outage reports), local permission denial, deadlines, and
cancellation do not increment the streak. The Workspace Worker details view
shows the failure count and rollback suggestion.

This phase supplies the policy boundary and UI state; it applies once the
native Worker assignment route invokes `WorkerFailurePolicy.run`. The current
first-party assignment path is still being migrated to the native Worker
supervisor, so live assignments do not yet consume this policy.

## Objective

Avoid unstable Worker releases repeatedly consuming assignments.

Track locally:
- Worker process crash;
- protocol violation;
- internal Worker error.

Recommended behavior:
- one bounded automatic retry/restart where safe;
- repeated Worker-internal failures -> `Needs attention`;
- suggest rollback when previous LKG exists.

Do not blame/rollback for:
- authentication;
- quota;
- provider outage;
- unsupported requested model;
- local permission denial.

## Exit

Worker-release failures are distinguished from provider/user failures.

---

# Phase 24 — Real ChatGPT production-path acceptance

**Status: Partial local acceptance passed; production path not accepted.** On
2026-09-30, the compiled Dart ChatGPT Worker was run against the locally signed-in
Codex CLI 0.158.0. Initialize, passive probe, live probe, stateless execution,
and durable session continuation all succeeded. The disabled Worker UI test
(`testing a disabled Worker preserves activation`) also passed. These live
requests may have consumed provider allowance.

The required Cloud -> Workspace Gateway -> Workspace -> Dart Worker route is
not available yet. `workspace_runtime.dart` still dispatches assignments via
`WorkerAssignmentHandler` and `V7AdapterPackageStore`; it does not launch
`WorkerProcessSupervisor` for ChatGPT assignments. Consequently, this run did
not verify production-path timeout/cancellation or ChatGPT Worker update and
rollback with Codex installed. Phase 24 remains incomplete and ChatGPT is not
yet a production candidate.

Run:

~~~text
Cloud
-> Workspace Gateway
-> Workspace
-> ChatGPT Dart Worker
-> real Codex CLI
-> result
-> Cloud
~~~

Test:
- passive probe;
- live probe;
- stateless assignment;
- durable session continuation;
- timeout;
- cancellation;
- disabled Worker Test;
- Worker update/rollback with Codex installed.

This test is opt-in because it may consume provider allowance.

## Exit

ChatGPT Worker is production-candidate.

---

# Phase 25 — Real Gemini production-path acceptance

**Status: Partial local acceptance passed; production path not accepted.** On
2026-09-30, the compiled Gemini Dart Worker was run against the local `agy`
1.2.14 CLI. Initialize, passive configuration checks, live probe, headless
stateless execution, and two turns of durable conversation continuation all
succeeded. Passive authentication was reported as a warning, as designed; the
live request verified provider access. The Gemini fake-provider test passed
(1/1), the disabled Worker UI test passed (1/1), and the generic native Worker
runtime suite passed (19/19), including timeout, cancellation, update, and
rollback coverage for the test Worker. Live requests may have consumed
provider allowance.

The required Cloud -> Workspace Gateway -> Workspace -> Dart Worker route is
not available yet. `workspace_runtime.dart` still dispatches assignments via
`WorkerAssignmentHandler` and `V7AdapterPackageStore`; it does not launch
`WorkerProcessSupervisor` for Gemini assignments. The generic release tests do
not verify update/rollback of an actual Gemini Worker release with `agy`
installed. Phase 25 remains incomplete and Gemini is not yet a production
candidate.

Run:

~~~text
Cloud
-> Workspace Gateway
-> Workspace
-> Gemini Dart Worker
-> real agy
-> result
-> Cloud
~~~

Test the same cases as ChatGPT plus Gemini-specific headless/session behavior.

## Exit

Gemini Worker is production-candidate.

---

# Phase 26 — Aggressive Node/adapter cleanup

**Status: Deferred; acceptance gate not met.** Phases 24 and 25 passed local
provider checks but did not pass the Cloud -> Workspace -> native Dart Worker
production path. The current `workspace_runtime.dart` assignment route still
uses `WorkerAssignmentHandler` and `V7AdapterPackageStore`. Do not delete that
route, the first-party Node executables, or their release tooling until native
Workspace assignment and release/update/rollback paths replace them and both
production-path acceptance suites pass.

**Repository audit classification (2026-09-30):**

- **Historical docs:** adapter-era passages in architecture snapshots and
  earlier decisions, including old V6/V7 implementation descriptions,
  ADR-012's original adapter model, and historical storage/release
  descriptions. Keep their historical meaning clear; do not treat those
  passages as current Worker Runtime v2 contracts. The applied migration
  `0022_v7_adapter_releases.sql` is also historical and must remain in the
  migration chain; the later Worker-release migration drops its table.
- **Migration notes:** ADR-017's explanation of the Node implementation being
  replaced, the Worker Runtime v2 roadmap's rename/search instructions and
  acceptance status, and the legacy-consumer section of the Worker manifest
  README. Retain these until convergence is complete, then consolidate them.
- **Bugs to remove after the gate:** Workspace's active V7 adapter executor,
  admission, protocol, catalog and package-store path; adapter version fields
  in the local registry, Studio/host protocol and UI; the old V7 runtime test
  bridge; first-party Codex/Antigravity `.mjs` executables, manifests, tests and
  shared `cli_tool_runner.mjs`; the V7 adapter release workflow and package /
  verification scripts; first-party Node prerequisite metadata; and legacy
  V7 adapter manifest/protocol schemas and exports after their consumers are
  removed. Cloud source no longer has the V7 adapter release API, but its old
  SQL migration remains historical. Codex CLI / `agy` names in product labels
  and local diagnostics are provider-tool metadata, not Workspace command
  execution, and remain valid under Phase 19.

Other `.mjs` files for website tooling, Cloud/build infrastructure and the
native Worker release publisher are not Worker runtime dependencies and are
outside this deletion. The Claude Code and Ollama adapter packages still have
Node implementations and prerequisite metadata; they are not the fixed
ChatGPT/Gemini first-party catalog, so migrate or retire them separately if
they remain supported. Their existence must not reintroduce Node into normal
ChatGPT/Gemini execution.

Only after both Dart Workers pass real acceptance:

Delete:
- first-party `.mjs` adapter executables;
- shared Node CLI runner;
- Node Worker acceptance harness where replaced;
- Node prerequisite metadata;
- adapter-specific first-party release scripts;
- provider-specific command strings from Workspace;
- legacy adapter package store/admission classes after replacements exist;
- adapter compatibility aliases no longer used;
- obsolete tests;
- obsolete docs.

Search repository for:

~~~text
V7Adapter
adapter package
adapterVersion
conclave-codex-adapter
conclave-antigravity-adapter
cli_tool_runner.mjs
node prerequisite
~~~

Classify every remaining occurrence as:
- historical docs;
- migration note;
- bug to remove.

## Exit

Normal first-party execution has zero Node runtime dependency.

---

# Phase 27 — Database/migration cleanup

**Status: Audit complete; destructive cleanup deferred.** The Phase 24/25
production-path acceptance gates remain open, so Worker Runtime v2 is not yet
ready for a destructive migration rebase. The current target schema is already
partly represented by `0035_worker_releases.sql` and
`0036_worker_inventory_v2.sql`; the latter drops and rebuilds inventory and
scheduling tables. The two schema acceptance suites passed (8/8 tests) against
the current migration chain, but this does not prove a new clean baseline or
production-path compatibility.

The local `apps/cloud/wrangler.jsonc` uses a local D1 database. The production
Wrangler config points to `conclave-production`, and `.github/workflows/deploy-app.yml`
applies the `apps/cloud/migrations-v6` chain remotely during deployment.
`scripts/migrate-production-d1.sh` also targets remote D1 and requires explicit
confirmation. Repository configuration cannot establish whether that remote
database contains shared/staging data or whether it is safe to reset. No remote
database was queried, exported, snapshotted, or changed. Preserve the existing
migration chain until the environment owner confirms the target and a
snapshot/export is available before any destructive reset. Production tooling
must also be gated against applying unreleased schemas before deployment is
allowed to resume.

The clean-room schema tests currently apply the ordered migration history, and
the development seed directory only has V4/V5 seeds. Baseline consolidation,
seed updates, schema-test rewrites, clean-room bootstrap changes, and production
migration-tool changes are still outstanding.

## Objective

Avoid an ever-growing chain of migrations for architectures never released.

After Worker Runtime v2 tests are green:

- consolidate development baseline migrations where safe for the project;
- remove obsolete adapter release schema;
- remove obsolete Worker inventory columns;
- update seeds;
- update D1 schema acceptance tests;
- update clean-room database bootstrap;
- ensure production migration tooling is not claiming compatibility with
  unreleased schemas.

If any shared/staging environment must be preserved, snapshot/export it before
the destructive reset rather than complicating runtime code.

## Exit

A clean database bootstrap produces only the current v7 + Worker Runtime v2
schema.

---

# Phase 28 — Documentation convergence

Update:
- ADR-003;
- ADR-012;
- ADR-015;
- Architecture v7;
- Protocol Boundaries;
- Technology Stack;
- Workspace UX contract;
- release operations;
- release trust/key rotation;
- README;
- root ROADMAP.

Mark Node adapter implementation docs historical/superseded.

## Exit

A new developer cannot reasonably conclude that first-party Workers are Node
scripts or that Workspace probes provider CLIs directly.

---

# Phase 29 — Third-Worker scalability proof

## Objective

Validate that Worker Runtime v2 actually supports 10+ Workers architecturally.

Implement a development-only third CLI Worker or fixture without changing:
- Workspace provider-specific code;
- Cloud assignment protocol;
- AX Worker selection model;
- process supervisor.

Allowed changes should be limited to:
- Worker catalog entry;
- Worker Dart package;
- release metadata;
- tests.

## Exit

The architecture demonstrates extension by package rather than modification of
Workspace internals.

---

# Recommended PR sequence

Do not implement all phases in one PR.

1. **PR 1 — ADR/docs + protocol 3.0 package skeleton**
2. **PR 2 — shared Dart CLI Worker runtime + test Worker**
3. **PR 3 — native Worker release manifest/store/update transaction**
4. **PR 4 — generic Workspace Worker supervisor rename/convergence**
5. **PR 5 — ChatGPT Dart Worker**
6. **PR 6 — Gemini Dart Worker**
7. **PR 7 — registry + Cloud inventory/release schema cleanup**
8. **PR 8 — Workspace Worker version/update/rollback UI**
9. **PR 9 — native Worker release CI**
10. **PR 10 — real ChatGPT/Gemini acceptance + rollback acceptance**
11. **PR 11 — Node/adapter code deletion**
12. **PR 12 — migration/docs consolidation + third-Worker proof**

## Temporary dual-runtime rule

A short implementation branch may contain both Node and Dart Workers while
ports are being validated.

Do **not** ship a product mode that dynamically chooses between both forever.

Convergence gate:

~~~text
ChatGPT Dart real acceptance passes
AND
Gemini Dart real acceptance passes
AND
update/rollback acceptance passes
THEN
delete Node implementation
~~~

## Definition of done

Worker Runtime v2 is complete when:

- no first-party Worker needs Node;
- Workspace never runs provider CLI commands;
- ChatGPT/Gemini are native Dart executables;
- Worker versions update independently;
- rollback works;
- provider sessions survive compatible Worker update;
- clean D1/local bootstrap contains no obsolete adapter model;
- real Cloud -> Workspace -> Worker -> provider acceptance passes for both;
- third Worker can be added without provider-specific Workspace changes.
