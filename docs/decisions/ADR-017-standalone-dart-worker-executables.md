# ADR-017: Standalone Versioned Dart Worker Executables

**Status:** Superseded for first-party provider implementation by [ADR-018](ADR-018-generic-cli-worker-engine-and-tool-profiles.md); retained as historical process-boundary evidence  
**Date:** 2026-09-30  
**Builds on:** ADR-003, ADR-012, ADR-015, ADR-016, Architecture v7  
**Refines:** ADR-012's legacy package implementation details and ADR-015 first-party Worker runtime implementation

## Context

Architecture v7 correctly moved provider-specific execution behind a local
Worker Package boundary:

~~~text
Conclave Cloud
-> Conclave Workspace
-> Worker Package
-> provider CLI/tool
~~~

The first implementation used Node.js `.mjs` Worker Packages. That proved the
process/protocol/package model, but it introduced an unnecessary runtime
dependency between Conclave Workspace and the provider CLI:

~~~text
Workspace
-> Node.js
-> JavaScript Worker Package
-> Codex/agy
~~~

A macOS GUI application does not necessarily inherit the same shell environment
as an interactive Terminal. A Node-backed Worker therefore depends on both:

- finding a compatible Node runtime;
- reconstructing enough shell/user environment for the Worker Package;
- then finding the actual provider CLI.

That is avoidable complexity for a native desktop product.

The project is still under active development and has no production migration
constraint that justifies preserving the legacy Node implementation, obsolete
adapter-named symbols, or obsolete database compatibility fields.

Dart can compile command-line programs to standalone architecture-specific
native executables that contain a small Dart runtime. Dart also provides
`Process.start` and normal stdin/stdout/stderr process control. This fits the
existing Workspace supervisor architecture without requiring Flutter UI code in
the Worker.

## Decision

### 1. Historical v7/v2 decision

This change does **not** create Architecture v8.

The Cloud/Workspace ownership model, Project/Workstream model, Workspace
lifecycle, and first-party catalog remain Architecture v7.

The local execution subsystem is versioned separately as:

> **Worker Runtime v2**

This avoids coupling a local implementation rewrite to an unrelated product or
Cloud architecture version.

### 2. First-party Workers are standalone console executables

The first-party v1 catalog remains:

| Product Worker | Worker executable | Provider tool |
| --- | --- | --- |
| ChatGPT | Conclave ChatGPT Worker | Codex CLI |
| Gemini | Conclave Gemini Worker | Antigravity `agy` |

The Conclave Worker is a **console application**, not a Flutter application and
not a Flutter plugin.

Preferred implementation language for first-party Workers is Dart.

Production artifacts are compiled with `dart compile exe` into self-contained
native executables.

Users do not install Dart, Flutter, Node.js, or another Worker runtime.

### 3. Worker executables are independently versioned from Workspace

These versions are independent:

~~~text
Conclave Workspace version
ChatGPT Worker version
Codex CLI version

Gemini Worker version
agy version
~~~

Updating one must not silently update the others.

A Worker executable update never owns provider CLI installation/update unless a
future explicit product decision says otherwise.

### 4. Worker executable lifecycle remains out-of-process

Conclave Workspace is the long-lived supervisor.

Default assignment lifecycle:

~~~text
Workspace
-> start one Worker executable process
-> Worker starts provider CLI child process
-> assignment completes/fails/cancels
-> Worker exits
-> provider child tree is gone
~~~

The provider CLI is therefore normally a grandchild of Workspace.

Per-assignment Worker processes remain the default because they provide:

- crash isolation;
- cancellation boundaries;
- bounded environment/secrets;
- clean Workstream CWD isolation;
- easy Worker version activation/rollback;
- no cross-assignment process contamination.

Long-running Worker daemons or persistent provider processes are future
optimizations only.

### 5. Workspace never executes provider tools directly

This is a hard architecture invariant.

Workspace must not execute:

- `codex --version`;
- `codex login status`;
- `agy --version`;
- provider authentication commands;
- provider session/resume commands;
- provider-specific probes of any kind.

Workspace communicates only with the Worker executable through the Local Worker
Protocol.

Provider executable discovery, environment construction, version detection,
authentication checks, live tests, session handling, provider output parsing,
and provider error mapping belong inside the Worker.

### 6. Shared Dart runtime packages implement generic CLI mechanics

First-party Workers should share reusable Dart packages conceptually like:

~~~text
packages/conclave_worker_protocol
packages/conclave_cli_worker_runtime

workers/chatgpt
workers/gemini
~~~

The shared CLI runtime owns generic mechanics:

- executable discovery;
- safe environment construction;
- process spawning;
- stdin/stdout/stderr;
- NDJSON/stream helpers;
- timeout/deadline handling;
- cancellation;
- process-tree cleanup;
- output limits;
- safe diagnostic capture;
- session-state storage;
- structured logging;
- common error/result primitives.

Provider Workers implement only provider-specific behavior:

- CLI candidate/tool identity;
- passive probe;
- live probe;
- execution arguments;
- event parsing;
- session ID extraction/resume;
- provider error classification;
- provider-specific environment policy.

### 7. Local Worker Protocol 3.0 is the clean Worker Runtime v2 boundary

Worker Runtime v2 introduces **Local Worker Protocol 3.0**.

It is intentionally separate from:

- AX <-> Cloud Human Product Protocol;
- Cloud <-> Workspace Runtime Protocol.

The protocol is provider-neutral and keeps stdout reserved for structured frames.

Baseline operations:

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

A Worker process identifies itself with:

- product Worker type;
- Worker executable version;
- negotiated protocol version;
- capabilities;
- Worker state schema version.

Workspace validates this identity against the signed release manifest before
using the process.

### 8. Worker releases are immutable platform artifacts

A Worker release is built per supported OS/architecture.

Example artifact identity:

~~~text
chatgpt
1.4.2
macos-arm64
~~~

Installed versions are immutable and are never patched in place.

Conceptual local layout:

~~~text
Workers/
  chatgpt/
    versions/
      1.4.0/
        worker
        manifest.json
      1.4.2/
        worker
        manifest.json
    state/
    active.json
    last-known-good.json

  gemini/
    versions/
    state/
    active.json
    last-known-good.json
~~~

Worker state is deliberately outside version directories.

### 9. Workspace owns Worker installation, activation, update and rollback

Workspace is the Worker package manager/supervisor.

Update transaction:

~~~text
discover release
-> download into staging
-> verify archive hash
-> verify manifest signature/digest
-> verify platform/protocol compatibility
-> install immutable version
-> run Worker self-check
-> run passive provider probe
-> atomically activate
-> retain previous last-known-good version
~~~

A failed candidate never replaces the current active Worker.

Rollback selects an already installed compatible version atomically.

### 10. Update policy is per Worker

Each Worker supports:

~~~text
automatic
notify
pinned
~~~

Initial product default should be **notify** while Worker Runtime v2 matures.

Pinned versions are not automatically replaced.

Workspace should retain at least the active version plus a small bounded number
of recent verified versions so rollback is immediate.

### 11. Worker protocol compatibility is range-based

A Worker release manifest declares its supported Local Worker Protocol range.

Workspace declares its own supported range.

A version may activate only when the ranges overlap.

The negotiated version is the highest mutually supported version.

Do not start an incompatible Worker and hope that initialization succeeds.

### 12. Worker state schema compatibility is explicit

Worker state, including provider-session mappings and cached provider-tool
metadata, is separate from the executable version.

Each Worker declares a state schema version/range.

Rollback must not silently activate an older executable that cannot read the
current Worker state.

For early Worker Runtime v2 releases, prefer a conservative stable state schema
over frequent migrations.

Provider session IDs remain local and never enter Conclave Cloud.

### 13. Workspace/package logging is structured and bounded

Every Worker uses the shared logging contract.

Minimum fields include:

~~~text
timestamp
level
workerType
workerVersion
component
event
runId/assignmentId when present
errorCode when present
durationMs when present
~~~

Never log provider tokens, API keys, auth cookies, raw credential environment,
or full prompts/file contents by default.

Worker stdout is reserved for Local Worker Protocol frames.

Worker stderr is reserved for bounded structured operational logging, with
Workspace retaining a redacted tail if the Worker crashes before sending a
protocol error.

### 14. Failure diagnostics distinguish three layers

Diagnostics must distinguish:

1. **Worker executable health**
   - can the executable start and speak the protocol?
2. **Provider-tool health**
   - can the Worker locate and passively probe Codex/agy?
3. **Live provider execution**
   - can a small explicit model request complete?

This distinction prevents provider quota/auth failures from being mistaken for
a broken Worker release.

### 15. Automatic rollback must only react to Worker/runtime failures

A future automatic rollback feature may react to:

- Worker process crash loops;
- Local Worker Protocol violations;
- internal Worker errors;
- systematic provider-output parser regressions.

It must not rollback because of:

- provider quota exhaustion;
- provider authentication expiry;
- provider outage;
- requested unsupported model;
- user/local permission denial.

Those are not Worker-release failures.

### 16. Provider CLI sandboxing remains provider execution policy

Worker Runtime v2 process isolation and provider CLI sandboxing are separate.

Workspace process-group supervision is retained so cancellation can terminate
the complete Worker/provider process tree.

Provider-specific sandbox flags remain inside each Worker.

Default first-party policy should remain restrictive for Cloud-triggered work,
while the exact provider flags are implementation details of the Worker.

### 17. Cloud receives safe Worker inventory, not local package internals

Cloud may receive safe operational metadata such as:

- stable Worker ID/type;
- activation/readiness;
- Worker executable version;
- provider tool name/version;
- capabilities;
- local concurrency ceiling;
- stable issue code;
- last-seen time.

Cloud does not receive:

- local executable paths;
- provider credential/session values;
- provider session IDs;
- raw Worker logs;
- local Worker state files.

### 18. Development migration may be destructive

Because Conclave is not in production, Worker Runtime v2 may aggressively
remove obsolete compatibility layers rather than preserve them.

The implementation plan may:

- delete Node `.mjs` first-party Worker runtime code;
- delete Node prerequisite handling;
- delete legacy adapter-only package fields;
- rename legacy release concepts to Worker release concepts;
- rebuild development D1 Worker/release tables;
- reset local Worker registry/package caches;
- remove obsolete Worker fields that are no longer part of ADR-015;
- delete compatibility migrations/tests that only exist for unreleased designs.

Stable ChatGPT/Gemini product slot identity should be preserved where useful,
but preserving unreleased legacy implementation state is not a requirement.

## Consequences

### Positive

- no Node/Dart SDK prerequisite on user machines;
- one native process boundary per Worker;
- independent Worker upgrades and rollback;
- stable provider-specific ownership boundary;
- shared Dart protocol/runtime code with Workspace;
- easier cross-platform first-party implementation;
- fewer shell-environment surprises;
- simpler support for 10+ Workers;
- cleaner diagnostics and version attribution;
- Worker bugs no longer require Workspace upgrades.

### Tradeoffs

- Worker release artifacts become OS/architecture specific;
- CI must build/sign multiple platform artifacts;
- macOS and Windows native Worker builds require native build runners/signing;
- Worker protocol/state compatibility becomes a real release responsibility;
- release catalog/update UI becomes more substantial;
- rollback requires disciplined state schema evolution.

## Core invariant

> **Conclave Workspace supervises Workers; it does not implement providers.
> A first-party Worker is an independently signed, versioned standalone Dart
> console executable. The Worker alone owns provider CLI discovery, probing,
> execution, sessions and provider-specific behavior. Workspace owns install,
> activation, rollback, process lifetime and the generic Local Worker Protocol.**

## References

- [Worker Runtime v2 Architecture](../architecture/WORKER_RUNTIME_V2.md)
- [Worker Runtime v2 Implementation Plan](../roadmaps/WORKER_RUNTIME_V2_IMPLEMENTATION.md)
- [ADR-015](ADR-015-first-party-worker-v1-contract.md)
- [Technology Stack](../architecture/TECH_STACK.md)
- [Dart native executable documentation](https://dart.dev/tools/dart-compile)


## Architecture v8 supersession

ADR-018 and Architecture v8 retain the strongest ADR-017 decisions—out-of-process execution, Dart-native runtime, Workspace supervision, provider credentials staying local, provider-neutral protocol, process-tree cancellation, and no provider commands in Workspace—but replace **one native Worker executable per provider** with **one generic CLI Worker Engine plus signed Tool Profiles**. New CLI integrations must follow v8 rather than adding another provider-specific Worker binary.
