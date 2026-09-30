# Worker Runtime v2 Implementation Plan

**Status:** Ready for implementation  
**Architecture:** [Worker Runtime v2](../architecture/WORKER_RUNTIME_V2.md)  
**Decision:** [ADR-017](../decisions/ADR-017-standalone-dart-worker-executables.md)  
**Product baseline:** Architecture v7 / ADR-015 ChatGPT + Gemini first-party catalog

## Goal

Replace the current Node-backed first-party Worker Package implementation with
independently versioned, signed, native Dart console executables while
aggressively removing unreleased adapter-era compatibility.

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

Prevent another partial migration where Node/adapter terminology remains mixed
with the new Worker executable model.

## Rename conceptually

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

Internal filenames may remain temporarily during implementation, but no new
code should add adapter terminology unless referring to migration/history.

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

## Exit

Golden protocol fixtures and malformed-frame tests pass in Dart.

---

# Phase 3 — Build a Worker SDK reference executable

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

---

# Phase 4 — Introduce Worker release manifest v2

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

---

# Phase 5 — Replace adapter release storage with Worker release storage

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

# Phase 6 — Implement immutable local Worker version store

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

# Phase 7 — Implement protocol/state compatibility admission

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

# Phase 8 — Implement per-Worker update policy

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

---

# Phase 9 — Implement Worker candidate validation transaction

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

---

# Phase 14 — Port Gemini Worker to Dart

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

---

# Phase 15 — Move session storage fully behind Worker executables

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

---

# Phase 16 — Clean local Worker registry schema

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

---

# Phase 18 — Rename Cloud/release APIs and domain types

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

adapterUnavailable
-> workerRuntimeUnavailable
~~~

Retain provider tool terminology only for Codex/agy-specific Worker
implementation/tests.

## Exit

New API/domain code has no adapter terminology except migration comments.

---

# Phase 19 — Integrate Worker runtime version into safe inventory

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

---

# Phase 20 — Update Workers UI for independent Worker versions

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

---

# Phase 22 — Add upgrade/downgrade acceptance suite

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

---

# Phase 23 — Add failure/crash-loop policy

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
