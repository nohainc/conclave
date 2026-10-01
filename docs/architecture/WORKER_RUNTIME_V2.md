# Worker Runtime v2 Architecture

**Status:** Historical v7 runtime design; superseded for first-party CLI integration by [Architecture v8](ARCHITECTURE_V8.md) / [ADR-018](../decisions/ADR-018-generic-cli-worker-engine-and-tool-profiles.md)  
**Architecture baseline:** Conclave Architecture v7  
**Decision:** [ADR-017](../decisions/ADR-017-standalone-dart-worker-executables.md)

## Canonical terminology

Runtime v2 documentation, code, tests, APIs, and user-facing text use these
terms consistently:

| Concept | Runtime v2 term |
| --- | --- |
| Installable, signed unit | Worker release/package |
| Version of that unit | Worker runtime version |
| Running executable instance | Worker process |
| Workspace-to-executable contract | Local Worker Protocol |

Use *adapter* only when naming a pre-existing legacy symbol or describing
migration history. New Runtime v2 work uses Worker terminology even when an
older implementation still has adapter-named files or classes. Provider tools
remain provider tools; they are not Worker releases or Workers.

> **v8 note:** Runtime v2 proved the correct out-of-process/process-supervision boundary and remains useful implementation history. Architecture v8 keeps that boundary but replaces separate ChatGPT/Gemini executables and per-provider Worker releases with one generic CLI Worker Engine plus signed Tool Profiles. Do not add new provider-specific first-party Worker binaries using this document.

## Purpose

Worker Runtime v2 replaces the legacy Node-backed Worker Package implementation
with independently versioned, signed, standalone Dart console executables.

The product model does not change:

~~~text
Conclave AX
-> Conclave Cloud
-> Conclave Workspace
-> Worker
-> provider CLI/tool
~~~

The local implementation becomes:

~~~text
Conclave Workspace (Flutter/Dart)
        |
        | Local Worker Protocol 3.0
        | NDJSON stdin/stdout
        v
Standalone Worker executable (Dart AOT)
        |
        | provider-specific CLI contract
        v
Codex CLI / agy / future provider tool
~~~

## 1. Runtime boundaries

### 1.1 AX <-> Cloud

Human Product Protocol.

Responsibilities:
- Projects;
- Workstreams;
- collaboration;
- Workstream default Workflow and canonical Step bindings;
- model selection;
- assignment creation;
- operational read models.

This boundary knows product Worker IDs such as `chatgpt` and `gemini`.

It does not know provider executable paths or Worker package internals.

### 1.2 Cloud <-> Workspace

Workspace Runtime Protocol.

Responsibilities:
- Workspace presence;
- safe Worker inventory;
- assignment delivery;
- lease/fencing;
- cancellation;
- progress/results;
- runtime transport/recovery.

Cloud sends product intent:

~~~text
workerTypeId = chatgpt | gemini
model = optional
prompt
timeout
sessionPolicy
~~~

Cloud never sends:
- `codex` paths;
- `agy` paths;
- executable paths;
- provider session IDs;
- local credential values.

### 1.3 Workspace <-> Worker executable

Local Worker Protocol 3.0.

Responsibilities:
- Worker identity/version handshake;
- passive/live probe;
- assignment execution;
- progress/result/error;
- provider-neutral diagnostics;
- session policy.

Transport:
- stdin: NDJSON request/control frames;
- stdout: NDJSON protocol frames only;
- stderr: bounded structured Worker logs.

Workspace owns the Worker process lifecycle.

### 1.4 Worker executable <-> provider tool

Provider-private boundary.

Examples:

~~~text
ChatGPT Worker
-> Codex CLI

Gemini Worker
-> agy
~~~

Only the Worker understands:
- provider CLI commands;
- provider output/event schemas;
- provider auth/config;
- provider session IDs;
- provider-specific environment;
- provider error text;
- provider sandbox flags.

## 2. Process model

### 2.1 Default execution

Each assignment starts a new Worker process:

~~~text
Workspace PID 100
└── ChatGPT Worker PID 200
    └── codex PID 300
~~~

Concurrent assignments may create independent trees:

~~~text
Workspace
├── ChatGPT Worker A
│   └── codex A
├── ChatGPT Worker B
│   └── codex B
└── Gemini Worker A
    └── agy A
~~~

The local concurrency ceiling controls how many trees may exist per Worker slot.

### 2.2 Cancellation

Workspace is the ultimate process owner.

Cancellation order:

1. send protocol cancellation when supported;
2. allow a short graceful shutdown window;
3. terminate Worker process group/tree;
4. verify descendants are gone;
5. report cancelled/timeout.

A Worker must not daemonize provider processes outside Workspace supervision.

### 2.3 Persistent sessions are not persistent processes

Worker Runtime v2 initially supports:

~~~text
stateless
durable_session
~~~

A durable session means:
- every assignment still uses a fresh Worker process;
- Worker state maps Conclave `sessionKey` to provider session ID locally;
- a new process resumes the provider session.

It does **not** require a long-lived Worker daemon.

Persistent Worker/provider processes are deferred until measured performance
justifies the additional lifecycle complexity.

## 3. Repository structure

Recommended source layout:

~~~text
packages/
  conclave_worker_protocol/
    lib/
    test/

  conclave_cli_worker_runtime/
    lib/
    test/

workers/
  chatgpt/
    bin/
      chatgpt_worker.dart
    lib/
    test/
    manifest.template.json
    README.md

  gemini/
    bin/
      gemini_worker.dart
    lib/
    test/
    manifest.template.json
    README.md
~~~

Workspace may import shared protocol/domain Dart packages.

Workspace must **not** import provider-specific Worker implementation packages.

## 4. Shared Dart Worker SDK

### 4.1 `conclave_worker_protocol`

Owns canonical Local Worker Protocol 3.0 models and validation:

- protocol versions;
- request IDs;
- initialize frames;
- probe frames;
- execute frames;
- progress;
- results;
- errors;
- stable issue/error codes;
- capability identifiers.

Both Workspace and Worker executables use this package.

There should be one canonical Dart representation of the local protocol.

If TypeScript tooling/tests need the schema, generate or validate from one
canonical protocol source; do not hand-maintain divergent wire contracts.

### 4.2 `conclave_cli_worker_runtime`

Generic CLI integration toolkit.

Recommended components:

~~~text
CliExecutableLocator
CliEnvironmentBuilder
CliCommandRunner
CliStreamingRunner
WorkerDeadlineController
WorkerSessionStore
WorkerLogger
WorkerDiagnosticCollector
WorkerProcessCleanup
WorkerOutputLimiter
WorkerError
~~~

The package must be provider-neutral.

`WorkerRuntime` is the provider-neutral NDJSON server used by executable
packages. It dispatches initialize, probe, and execute requests, emits bounded
progress/result/error frames, enforces request deadlines, and writes structured
logs to stderr. Workspace process-tree termination remains the cancellation
authority even when an implementation is running work that cannot be
interrupted cooperatively.

`workers/test_worker` is a development-only reference executable. It provides
fake passive/live checks, deterministic echo output, a local fake durable
session, and delay controls for process-supervision acceptance tests. It is
excluded from the first-party Worker catalog and makes no provider requests.

## 5. Worker executable contract

### 5.1 Startup

Workspace starts the absolute Worker executable path directly.

No shell is required.

No Node.js or Dart SDK is required on the target machine.

Workspace provides:
- working directory;
- private Worker state directory;
- generic bounded environment;
- assignment-local identifiers through protocol;
- no provider credentials unless a future Worker explicitly declares a local
  secure secret requirement.

### 5.2 Initialize

Workspace chooses a mutually compatible protocol version from the signed
manifest and sends:

~~~json
{
  "type": "initialize.request",
  "protocolVersion": "3.0",
  "requestId": "...",
  "workerTypeId": "chatgpt",
  "expectedWorkerVersion": "1.4.2"
}
~~~

Worker replies with:

~~~json
{
  "type": "initialize.result",
  "protocolVersion": "3.0",
  "requestId": "...",
  "workerTypeId": "chatgpt",
  "workerVersion": "1.4.2",
  "stateSchemaVersion": 1,
  "capabilities": [
    "execute",
    "passive_probe",
    "live_probe",
    "durable_session"
  ]
}
~~~

Workspace rejects:
- wrong Worker Type;
- wrong executable version;
- incompatible state schema;
- unsupported capability requirements;
- malformed protocol output.

### 5.3 Passive probe

Passive probe must not consume provider model quota.

It should normally determine:

~~~text
provider tool located?
provider tool version?
local auth/config plausibly usable?
required local permissions/config present?
~~~

Response exposes safe structured data:

~~~json
{
  "type": "probe.result",
  "mode": "passive",
  "ready": true,
  "tool": {
    "name": "Codex CLI",
    "version": "0.x.y"
  },
  "checks": [...]
}
~~~

Local executable path may be returned to Workspace for local diagnostics, but
must not be synchronized to Cloud.

### 5.4 Live probe

Live probe is explicit because it may consume provider quota.

It verifies a minimal real execution.

Workspace UI must communicate that Test may use provider quota.

Testing does not enable/disable the Worker.

### 5.5 Execute

Baseline request:

~~~json
{
  "type": "execute.request",
  "protocolVersion": "3.0",
  "requestId": "...",
  "assignmentId": "...",
  "prompt": "...",
  "model": null,
  "timeoutMs": 600000,
  "sessionPolicy": "stateless"
}
~~~

For durable sessions:

~~~json
{
  "sessionPolicy": "durable_session",
  "sessionKey": "opaque-conclave-key"
}
~~~

Provider session identifiers never cross this protocol.

### 5.6 Result

~~~json
{
  "type": "result",
  "requestId": "...",
  "assignmentId": "...",
  "output": "...",
  "artifacts": []
}
~~~

The Workstream directory is the artifact/work product boundary. Worker stdout
should not serialize modified repository contents.

### 5.7 Protocol 3.0 frame validation

The Local Worker Protocol uses one JSON object per NDJSON line. Every request
and response has a bounded `requestId`; each frame has an exact allowlist of
fields, and unknown fields are rejected. The required frame set is:

| Frame | Required data |
| --- | --- |
| `initialize.request` | negotiated protocol, product Worker Type, expected Worker version |
| `initialize.result` | protocol, Worker Type/version, state schema version, capabilities |
| `probe.request` | protocol, request ID, explicit `passive` or `live` mode |
| `probe.result` | mode, readiness, optional tool details, structured checks, issue code, bounded diagnostics |
| `execute.request` | protocol, request/assignment IDs, prompt, optional model, timeout, session policy, optional logical session key |
| `progress` | request/assignment IDs, percentage, optional bounded message |
| `result` | request/assignment IDs, output, bounded artifact references |
| `error` | request ID, stable issue code, safe message, retryability, optional assignment ID/diagnostics |

Initialize admission compares the returned identity and exact version with the
signed release, checks the negotiated protocol and readable state-schema range,
and verifies all required capabilities. Protocol bounds limit frame and text
sizes, tool/check collections, and timeouts. Safe error, progress, and probe
text is redacted before serialization.

Passive probe mode is a promise that the Worker will not issue a provider model
request. Live mode must be selected explicitly because it may consume provider
quota. A probe result's provider tool path is local diagnostics only and must
not enter Cloud inventory.

Execute requests use a strict field allowlist. They carry only Conclave-owned
assignment inputs; provider credentials, provider session IDs, executable
paths, and working directories are rejected. Durable sessions carry an opaque
Conclave `sessionKey`; provider session IDs remain inside Worker state.

## 6. Worker package/release format

A release is a signed immutable platform artifact.

Conceptual manifest:

~~~json
{
  "manifestVersion": 2,
  "workerTypeId": "chatgpt",
  "workerVersion": "1.4.2",
  "publisher": "conclave",
  "platform": "macos-arm64",
  "protocol": {
    "min": "3.0",
    "max": "3.0"
  },
  "stateSchema": {
    "readMin": 1,
    "readMax": 1,
    "write": 1
  },
  "capabilities": [
    "execute",
    "passive_probe",
    "live_probe",
    "durable_session"
  ],
  "permissions": [
    "workspace:read",
    "workspace:write",
    "shell:execute"
  ],
  "executable": "bin/conclave-chatgpt-worker",
  "packageDigest": "...",
  "archiveSha256": "...",
  "signingKeyId": "...",
  "signature": "...",
  "releaseChannel": "stable"
}
~~~

The manifest is a signed sidecar to the native artifact archive. Keeping it
detached avoids a hash/signature cycle: `archiveSha256` covers the exact
compressed archive bytes, `packageDigest` covers the sorted extracted file
paths, modes, and contents, and the Ed25519 signature covers the canonical
manifest with only `signature` omitted. Workspace checks both digests and the
signature before admitting the package.

No provider command strings are required in the manifest.

Provider details belong in the executable.

## 7. Platform builds

Dart native executables are architecture-specific.

Initial artifact matrix:

~~~text
macos-arm64
macos-x64

windows-x64
windows-arm64 when supported/tested

linux-x64
linux-arm64
~~~

macOS and Windows releases should be built/sign-tested on their native CI
platforms.

Linux may use Dart's supported Linux cross-compilation where useful, but native
CI remains preferred for final acceptance.

Each artifact must pass the same Local Worker Protocol contract suite.

## 8. Local installation layout

Recommended:

~~~text
<WorkspaceData>/
  Workers/
    chatgpt/
      versions/
        1.4.0/
          bin/conclave-chatgpt-worker
          manifest.json
        1.4.2/
          bin/conclave-chatgpt-worker
          manifest.json

      state/
        sessions/
        metadata/

      logs/
      release-state.json

    gemini/
      versions/
      state/
      release-state.json
      logs/
~~~

`release-state.json` stores non-secret local release intent:

~~~json
{
  "schemaVersion": 1,
  "updatePolicy": "notify",
  "pinnedVersion": null,
  "activeVersion": "1.4.2",
  "lastKnownGoodVersion": "1.4.0",
  "healthyVersions": ["1.4.0", "1.4.2"],
  "updatedAt": "2026-09-30T12:00:00Z"
}
~~~

Worker versions are extracted into a staging directory, verified against the
signed manifest, archive hash, package digest, platform, protocol, state range,
and local permissions, then moved into `versions/<version>`. An installed
version is never overwritten. `release-state.json` is replaced atomically so
Workspace sees either the previous active version or the new active version;
the same record tracks the last-known-good version. Worker `state/` and `logs/`
remain outside version directories and survive activation, rollback, and
retention cleanup. Staging directories left by a process interruption are
removed after they are at least one hour old. Retention keeps at least the
active and last-known-good versions.

Update policy is local and independent for each Worker Type. New releases
default to `notify`; `automatic` checks the stable Worker release catalog and
activates a newer compatible release when no assignment is running. `pinned`
records an installed version and blocks activation of another version until
the pin is changed or removed. Workspace presents the active and available
versions, install/update action, installed versions, rollback action, and
advanced policy controls. Worker release installation only downloads and
verifies the native Worker artifact; it does not install or update provider CLI
tools.

Every downloaded release remains a candidate until its immutable executable
starts, returns an initialize identity matching the signed manifest, and passes
an explicit passive provider probe. Workspace terminates the candidate process
tree after validation. A failed candidate writes a bounded local diagnostic
without changing the active/last-known-good pointers or Worker scheduling
readiness. A successful health record and version-pointer change are committed
atomically. Automatic updates never run a live/quota-consuming probe and skip a
version already recorded as failed.

Candidate failure details are stored separately at
`Workers/<workerTypeId>/candidate-failure.json`; the record contains only the
release version, stable issue code, bounded safe diagnostic, and failure time.
An installed version may be selected for rollback only when its version is
currently active, last-known-good, or recorded in `healthyVersions`.

Workspace admission requires its current platform and state schema version,
and at least one Workspace-supported protocol version inside the Worker
release's protocol range. The Worker manifest's requested permissions must be
allowed locally. Before assignment execution, the `initialize.result` identity
must match the admitted manifest's Worker Type, exact version, negotiated
protocol, and declared state-write schema; required capabilities must also be
present.

Never store provider credentials in release state.

## 9. Release state machine

~~~text
not_installed
-> downloading
-> staged
-> verified
-> self_checking
-> provider_probing
-> candidate_ready
-> active
~~~

Failure returns to the previously active version.

Activation must be atomic from Workspace's perspective.

Do not delete the previous last-known-good version during activation.

## 10. Update policy

Per Worker:

### Notify — initial default

Workspace checks for a newer compatible release and displays:

~~~text
ChatGPT Worker
1.4.2
Update available: 1.5.0

[Update]
~~~

### Automatic

Workspace installs/verifies candidate in the background and activates when:
- no conflicting active assignment lifecycle prevents activation;
- candidate self-check/probe succeeds;
- state/protocol compatibility passes.

### Pinned

Workspace reports available releases but never automatically changes the active
Worker.

## 11. Rollback

Rollback is a normal product operation, not emergency filesystem surgery.

Requirements:
- target version already verified/installed;
- protocol compatible;
- Worker state readable by target;
- no conflicting active assignment;
- atomic active-version change;
- post-switch initialize + passive probe;
- automatic return to previous active version if post-switch validation fails.

Normal UI may show Current/Previous and available installed versions.

Advanced Diagnostics may show exact executable paths/digests.

## 12. State schema

Provider session state belongs to the Worker.

Example:

~~~text
Workers/chatgpt/state/sessions/<hash>.json
~~~

Session files should contain only the minimum required provider session mapping
and no Cloud credentials.

A Worker executable must declare state read/write compatibility.

Avoid irreversible migrations while rollback is a core feature.

When a migration is eventually necessary:

1. snapshot/backup minimal Worker state;
2. migrate transactionally;
3. validate;
4. keep rollback path explicit.

## 13. Environment model

The user should not need to configure Conclave-specific environment variables
for normal subscription-backed CLI use.

Workspace supplies a generic OS baseline:
- home directory;
- temp directory;
- locale;
- TLS certificate variables where present;
- deterministic safe PATH;
- Worker state directory.

The Worker may extend provider CLI environment from:
- its own provider-specific allowlist;
- existing user environment values already available to Workspace;
- local secure settings explicitly configured by the user.

Workspace does not know what provider-specific variables mean.

The Worker owns provider-specific interpretation.

## 14. Provider CLI discovery

Generic discovery algorithm in the shared Dart runtime:

~~~text
1. cached previously verified absolute path
2. current bounded PATH
3. standard user/system locations
4. bounded platform-specific discovery fallback
5. not installed
~~~

Successful absolute path is cached as non-secret local Worker metadata.

Workspace sees it only for local diagnostics.

## 15. ChatGPT Worker

Product identity:

~~~text
workerTypeId = chatgpt
~~~

Responsibilities:
- discover Codex CLI;
- detect version;
- passive login/config check;
- explicit live test;
- execute Codex assignment;
- parse structured Codex output;
- map provider failures to Conclave error codes;
- support durable Codex sessions when reliable;
- manage provider-specific sandbox/approval flags;
- preserve provider credentials entirely inside Codex.

Workspace never calls Codex directly.

## 16. Gemini Worker

Product identity:

~~~text
workerTypeId = gemini
~~~

Responsibilities:
- discover `agy`;
- detect version;
- validate local auth/config without reconstructing credentials;
- explicit live test;
- execute headless/streaming `agy`;
- parse provider events;
- map errors;
- manage durable conversation IDs locally;
- manage provider-specific sandbox/permission mode.

Workspace never calls `agy` directly.

## 17. Error taxonomy

Provider-neutral baseline:

~~~text
worker_not_ready
worker_protocol_error
worker_internal_error
worker_version_incompatible

cli_not_found
unsupported_cli_version
authentication_required
model_not_supported
permission_denied
quota_exhausted
provider_unavailable
timeout
cancelled
execution_failed
execution_test_failed
session_resume_failed
~~~

Raw provider error text stays local and bounded.

Cloud/AX primarily consume stable codes.

## 18. Logging

### Worker log

Structured JSONL under the Worker local log directory.

Rotate by size/count.

### Assignment diagnostic

Capture bounded:
- Worker version;
- provider tool version;
- process exit;
- duration;
- stable error code;
- redacted stderr tail;
- protocol stage;
- session mode.

Cloud's safe Worker inventory stores the current Worker runtime version,
provider tool name/version, and readiness. Assignment creation copies the
selected Worker runtime and provider tool versions into the persisted
assignment permission snapshot, so a later CLI or Worker update does not
rewrite the versions associated with an earlier failure. Provider tool paths
remain local to Workspace diagnostics.

Do not log prompts or file contents by default.

### Workspace log

Workspace records:
- Worker selected version;
- process start/exit;
- protocol handshake;
- cancellation/timeout;
- activation/rollback.

This allows failures to be attributed to:
- Workspace;
- Worker executable;
- provider CLI;
- provider service.

## 19. Cloud release catalog

Replace legacy release semantics with Worker release semantics.

Conceptually:

~~~text
worker_releases
  worker_type_id
  version
  platform
  release_channel
  protocol_min
  protocol_max
  state_read_min
  state_read_max
  state_write
  capabilities_json
  manifest_json
  package_digest
  archive_sha256
  package_r2_key
  revoked
  created_at
~~~

Release uniqueness should include platform:

~~~text
(worker_type_id, version, platform)
~~~

This differs from the legacy release table whose primary key does not model
platform-specific native binaries cleanly.

## 20. Cloud Worker inventory v2

Because the product has exactly one ChatGPT and one Gemini slot per Workspace,
development can simplify the inventory schema.

Desired safe projection:

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

Remove obsolete unreleased fields such as:
- display Worker name;
- auth strategy projection;
- credential status projection;
- default model;
- allowed models;
- local permissions summary;
- legacy release-version terminology.

Local provider tool path stays local.

## 21. Security model

Workspace verifies:
- publisher trust;
- manifest signature;
- archive hash;
- package digest;
- supported platform;
- requested permissions;
- protocol compatibility;
- Worker identity/version handshake.

Cloud cannot provide arbitrary local executable paths.

Worker cannot broaden Workspace-approved local permissions.

Provider secrets remain outside Cloud.

## 22. Future Worker SDK

A third first-party Worker should require:

1. a Dart console package;
2. a Worker definition using the shared CLI runtime;
3. protocol contract tests;
4. platform build/release;
5. provider-specific live acceptance.

It should not require new provider-specific code in Workspace.

That is the scalability acceptance criterion for Worker Runtime v2.

## 23. Non-goals

Worker Runtime v2 does not:
- turn Workers into Flutter UI apps;
- require Dart SDK on user machines;
- bundle Codex/agy provider CLIs;
- make Workers connect to Cloud;
- make Cloud manage provider credentials;
- keep one Worker process permanently alive;
- change the first-party ChatGPT/Gemini product catalog;
- create Architecture v8.

## Acceptance summary

Worker Runtime v2 is complete when:

1. Workspace can run both native Dart Worker executables with no Node runtime;
2. Workspace never executes provider CLI commands directly;
3. Worker versions update/rollback independently;
4. ChatGPT Worker discovers/probes/executes Codex;
5. Gemini Worker discovers/probes/executes `agy`;
6. disabled/readiness semantics remain independent;
7. process-tree cancellation leaves no provider descendants;
8. durable sessions work through fresh Worker processes;
9. Cloud inventory contains only safe Worker/runtime metadata;
10. adding a third Worker does not require provider-specific Workspace code.


## v8 retained vs superseded

Retained: Workspace-owned execution, isolated child process, provider credentials local, process-tree cancellation, generic Dart runtime primitives, durable provider-session mapping, structured logs/diagnostics, and no provider commands in Workspace.

Superseded: per-provider native Worker executable, per-provider native Worker release/version management, provider behavior compiled into ChatGPT/Gemini Worker packages, and Local Worker Protocol 3.0 executable identity. v8 uses Local Worker Protocol 4.0 with Engine + Profile identity. See [Architecture v8](ARCHITECTURE_V8.md) and the [v8 implementation roadmap](../roadmaps/ARCHITECTURE_V8_IMPLEMENTATION.md).
