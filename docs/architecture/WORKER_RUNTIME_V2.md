# Worker Runtime v2 Architecture

**Status:** Accepted design for implementation  
**Architecture baseline:** Conclave Architecture v7  
**Decision:** [ADR-017](../decisions/ADR-017-standalone-dart-worker-executables.md)

## Purpose

Worker Runtime v2 replaces the first Node-backed Worker Package implementation
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
- Worker usage policy;
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

## 6. Worker package/release format

A release is a signed immutable platform artifact.

Conceptual manifest:

~~~json
{
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

      release-state.json
      logs/

    gemini/
      versions/
      state/
      release-state.json
      logs/
~~~

`release-state.json` stores non-secret local release intent:

~~~json
{
  "activeVersion": "1.4.2",
  "lastKnownGoodVersion": "1.4.0",
  "updatePolicy": "notify",
  "pinnedVersion": null
}
~~~

Never store provider credentials there.

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

Replace adapter-centric release semantics with Worker release semantics.

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

This differs from the current adapter table whose primary key does not model
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
- adapter version terminology.

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
