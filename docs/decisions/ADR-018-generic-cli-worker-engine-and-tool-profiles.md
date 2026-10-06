# ADR-018: Generic CLI Worker Engine and Signed Tool Profiles

**Status:** Accepted for Architecture v8 implementation  
**Date:** 2026-10-01  
**Decision:** one generic Engine with signed Tool Profiles for all supported local CLI Workers.
**Preserves:** ADR-012 Workspace ownership, ADR-015 logical Worker catalog, ADR-016 AX-owned Worker usage

## Context

The runtime requires a clear process and security boundary:

~~~text
Conclave Workspace
-> isolated Worker process
-> provider CLI
~~~

Provider-specific behavior should not require a separate Workspace executable.
Process supervision, executable discovery, environment
construction, streaming, output limits, deadlines, cancellation, session
storage, logging, diagnostics, and the Local Worker Protocol. The remaining
differences are mostly declarative provider/tool behavior:

- executable discovery;
- version detection;
- authentication/readiness probe;
- CLI arguments;
- prompt transport;
- output/event extraction;
- model parameter mapping;
- session/resume mapping;
- progress events;
- stable error mappings;
- provider environment allowlist.

When behavior can be represented safely as bounded, signed data, a shared
engine avoids duplicating common runtime code.

## Decision

Architecture v8 uses **one generic Conclave CLI Worker Engine executable** for
all supported local CLI-based Workers.

Logical product Workers remain stable:

~~~text
ChatGPT
Gemini
future approved Workers
~~~

but they are implemented through signed, immutable, versioned **Tool Profile
releases** interpreted by the generic engine.

~~~text
Conclave Workspace
        |
        | Local Worker Protocol 4.0
        v
Conclave CLI Worker Engine
        |
        | signed Tool Profile
        v
provider CLI
~~~

Examples:

~~~text
ChatGPT
-> CLI Worker Engine
-> profile chatgpt-codex
-> codex

Gemini
-> CLI Worker Engine
-> profile gemini-antigravity
-> agy
~~~

## 1. Separate product identity from runtime implementation

A logical Worker Type remains the product-facing identity used by AX, Cloud,
Workflows, Workstream bindings, scheduling, and history.

This identity is stored in `worker_catalog` and remains distinct from its
implementation binding in `tool_profile_definitions`. Signed versioned
behavior belongs to `tool_profile_releases`. An implementation can be
replaced by retiring its Definition and activating another while retaining the
same Worker Type ID; at most one Definition may be active for a Worker.

Example:

~~~text
workerTypeId = chatgpt
~~~

The implementation is resolved separately:

~~~text
engine = conclave-cli-worker
profileDefinition = chatgpt-codex
profileRelease = 9
providerTool = codex
providerToolVersion = 0.x.y
~~~

Changing the active profile release does not change the logical Worker ID and
does not invalidate Workstream bindings such as:

~~~text
Implement -> ChatGPT
Verify    -> Gemini
~~~

## 2. One generic engine binary

The CLI Worker Engine is a standalone Dart console executable.

It is not:
- part of the Flutter UI process;
- one binary per provider;
- a shell wrapper;
- a user-editable script host.

Workspace starts one engine process per assignment/probe by default. The engine
starts the provider CLI as its child process.

~~~text
Workspace
├── CLI Worker Engine [chatgpt-codex profile 9]
│   └── codex
└── CLI Worker Engine [gemini-antigravity profile 6]
    └── agy
~~~

Workspace remains the ultimate process-tree owner.

## 3. Tool Profiles are immutable executable-behavior releases

A Tool Profile release is configuration with code-like trust requirements.

A profile release may describe only behavior supported by the engine's typed
profile schema. It cannot contain arbitrary executable code or general-purpose
expressions.

Profile releases are immutable and independently versioned.

Example:

~~~text
profileDefinitionId = chatgpt-codex
release = 9
status = stable
~~~

A newer release is a new row/payload, never an in-place mutation.

## 4. Profile lifecycle is Cloud-managed

Official profile releases have explicit lifecycle states:

~~~text
draft
testing
beta
stable
retired
revoked
~~~

Only releases allowed by the Workspace/profile channel policy are eligible for
normal use.

Promotion changes release/channel pointers; it does not mutate the signed
profile payload.

Example:

~~~text
chatgpt-codex
  v8 retired
  v9 stable
  v10 testing
~~~

Rollback can move the stable pointer back to a previously trusted compatible
release without rebuilding Workspace or the engine.

## 5. Official profiles only in the first v8 product

Architecture v8 does not expose profile creation/editing to normal users.

The first product supports only Conclave-approved, signed official profiles.

Normal Workspace UI continues to show logical Workers:

~~~text
ChatGPT  Ready
Codex 0.x

Gemini   Ready
agy x.y
~~~

Profile and engine details live under Advanced Diagnostics.

Custom/local profiles are a possible future capability, not a v8 requirement.

## 6. Profiles are data, but treated as code

Every official profile release requires:

- schema validation;
- fixture tests;
- compatibility tests;
- review;
- signing;
- immutable release storage;
- lifecycle promotion;
- rollback/revocation;
- audit history.

Database write access alone does not make a profile trusted.

Workspace uses only a profile payload whose signature, digest, schema,
compatibility, and lifecycle eligibility pass local verification.

## 7. Profiles cannot weaken engine security invariants

The engine owns non-configurable safety boundaries.

A Tool Profile cannot:
- enable shell execution;
- request `runInShell=true`;
- disable process/output/deadline limits;
- inherit the complete parent environment;
- execute arbitrary helper scripts;
- escape the admitted Workstream/Worker state roots;
- disable session-integrity checks;
- bypass Workspace-approved local permissions;
- disable profile signature/schema verification.

Provider-specific sandbox/approval flags may be selected only through a bounded
engine-supported policy mapping.

## 8. Structured arguments, never shell command strings

Profiles specify executable/arguments as structured values.

Bad:

~~~text
"codex exec ... | jq ..."
~~~

Allowed conceptually:

~~~json
{
  "executable": "codex",
  "arguments": ["exec", "--json", "..."]
}
~~~

The engine always launches provider processes with shell execution disabled.

## 9. Profile schema is intentionally finite

The initial typed schema supports bounded primitives for:

- executable candidates and standard discovery paths;
- version command and version extraction;
- supported tool-version ranges;
- passive auth/config probes;
- execution argument templates;
- raw-text or bounded JSON stdin templates;
- output mode: text, JSON, JSONL/stream;
- event match/extract rules;
- final text extraction;
- provider session extraction;
- resume argument construction;
- model argument construction;
- progress mapping;
- provider error mapping;
- provider-specific environment allowlist;
- provider timeout mapping;
- sandbox/permission mode mapping.

The profile language must not evolve into a general-purpose scripting language.

When a future CLI cannot be represented safely:
1. add a small generic engine capability only if broadly reusable; or
2. implement a separately reviewed specialized driver/engine family.

## 10. Tool-version compatibility belongs to Profile releases

A profile release declares which provider CLI versions it supports.

Small differences may be represented as bounded version-specific overrides.

Material behavior changes should normally produce a new profile release.

Example:

~~~text
chatgpt-codex v9
supports codex >=0.160 <0.176

chatgpt-codex v10
supports codex >=0.176 <0.190
~~~

Workspace/engine chooses an eligible compatible profile release for the
installed provider tool version.

Unknown unsupported provider versions fail closed by default.

## 11. Engine, Profile, and provider tool versions are independent

Diagnostics and assignment evidence distinguish:

~~~text
Workspace version
CLI Worker Engine version
Tool Profile definition + release
provider CLI version
provider model, when explicitly selected
~~~

Example:

~~~text
Workspace            0.9.0
CLI Worker Engine    1.2.0
Profile              chatgpt-codex@9
Codex CLI            0.177.0
~~~

Engine downgrade remains supported because engine bugs are possible, but
provider compatibility updates should normally require only a profile release.

## 12. Workspace caches active and last-known-good profiles

Workspace keeps locally verified profile payloads.

Conceptually:

~~~text
Profiles/
  chatgpt-codex/
    8/
    9/
    release-state.json
~~~

Release state includes:
- active profile release;
- last-known-good profile release;
- channel/policy;
- last verification/probe result.

A failed candidate does not replace the working active profile.

A revoked profile is never eligible for rollback.

## 13. Profile activation is transactional

Candidate activation:

~~~text
download signed payload
-> verify digest/signature
-> validate schema
-> validate engine compatibility
-> validate provider tool compatibility
-> start engine with candidate
-> initialize
-> passive probe
-> atomically activate
-> retain previous last-known-good
~~~

A live model test is not required for every automatic profile update because it
may consume provider quota. Testing/beta promotion pipelines may run explicit
live acceptance.

## 14. Local Worker Protocol 4.0

Architecture v8 introduces Local Worker Protocol 4.0.

The main identity changes from "one provider-specific Worker executable version"
to:

~~~text
logical workerTypeId
engineVersion
profileDefinitionId
profileReleaseVersion
providerToolName
providerToolVersion
~~~

The protocol still supports provider-neutral:
- initialize;
- passive/live probe;
- execute;
- progress;
- result;
- error;
- durable session policy.

Provider session IDs remain local.

## 15. Session integrity stays compiled into the engine

Profiles describe:
- how to extract a provider session ID;
- how to add a resume/session argument.

The engine enforces:
- requested durable session continuity;
- expected vs observed session identity;
- bounded session IDs;
- local state persistence;
- mismatch failure rather than silent fallback.

This prevents a profile from weakening continuity guarantees.

## 16. Cloud owns the official profile catalog and release metadata

Cloud stores product/profile metadata and signed profile releases.

Conceptual entities:

~~~text
worker_catalog
tool_profile_definitions
tool_profile_releases
tool_profile_channel_pointers
tool_profile_release_audit
~~~

The signed payload may live in D1 when comfortably bounded or R2 with D1
metadata/pointers. Trust does not depend on storage location.

## 17. New logical Workers can be added without a Workspace binary release

When a new approved CLI integration fits the existing engine/profile schema,
Conclave may publish:

~~~text
Worker catalog entry
+
Tool Profile definition
+
stable signed Profile release
~~~

Workspace can then expose the new logical Worker after catalog/profile sync,
without a new native provider Worker binary.

This is a v8 architectural capability. Product rollout may still gate which
Workers are visible.

## 18. Keep the current Workspace UX

Normal users manage logical Workers, not engine/profile implementation.

The first v8 UX remains conceptually:

~~~text
Workers

ChatGPT
Codex 0.177
Ready

Gemini
agy 1.x
Ready
~~~

Advanced Diagnostics may show:

~~~text
Engine             1.2.0
Integration        chatgpt-codex@9
Profile channel    Stable
Provider tool      Codex 0.177
~~~

No profile editor is exposed in v8.

## 19. Work v1 remains unchanged above the runtime boundary

Architecture v8 does not change the constrained Work v1 model:

~~~text
Chat
Research
Plan
Implement
Test
Verify
~~~

or built-in Workflows:

~~~text
Chat
Work
Research
Plan & Implement
Implement & Verify
Full Cycle
~~~

Workstream bindings still target logical Workers:

~~~text
Implement -> ChatGPT
Verify    -> Gemini
~~~

The profile/engine implementation is resolved locally beneath that abstraction.

Chat is read-only with a durable Workstream provider conversation and no mutation
lease. Work is the display name of current `direct:v2`, with writable mutation
coordination and a separate durable conversation. Historical `direct:v1` remains
Direct; persisted `direct` bindings and identifiers are unchanged.

## 20. Engine families remain extensible

The v8 engine introduced here is specifically a **CLI Worker Engine**.

Future execution technologies may use different generic engine families:

~~~text
CLI Worker Engine  -> CLI Tool Profiles
HTTP/API Engine    -> future API Profiles
MCP Engine         -> future MCP Profiles
~~~

Do not force non-CLI integrations into command-line emulation.

## 21. Scope

Conclave uses one generic CLI Worker Engine and signed Tool Profiles for normal
CLI execution. Logical ChatGPT/Gemini Worker IDs and Workstream bindings remain
stable across Engine and Profile releases. Release status and acceptance
evidence are tracked in the [v8 implementation plan](../roadmaps/ARCHITECTURE_V8_IMPLEMENTATION.md).

## Consequences

### Benefits

- one native CLI engine per platform instead of one binary per provider;
- fast profile-only provider compatibility updates;
- profile testing/beta/stable channels;
- lightweight rollback;
- fewer native build/signing artifacts;
- easier support for many CLI integrations;
- easier support for multiple provider CLI versions;
- stable UI/Workflows despite implementation changes;
- better diagnostic separation between engine/profile/tool failures.

### Costs

- Tool Profile schema becomes security-critical infrastructure;
- profile interpreter complexity must remain bounded;
- profile release/signing/testing pipeline becomes mandatory;
- version-resolution logic becomes more sophisticated;
- some unusual CLIs may still require engine changes or specialized drivers.

## Core invariant

> **Workspace supervises one generic isolated CLI Worker Engine. Official signed
> Tool Profiles describe supported CLI behavior within a finite schema. Profiles
> may change provider integration behavior, but they cannot weaken engine or
> Workspace security invariants. Logical Workers remain stable product
> identities above the engine/profile layer.**

## Local development exception (2026-10-04)

Production Workspaces continue to admit only signed Profiles. At the operator's
explicit request, a non-release Workspace can opt into unsigned local drafts
with `CONCLAVE_DEVELOPMENT_PROFILE_DIRECTORY`, provided its Cloud origin is
loopback. This bounded exception uses the same generic CLI Worker Engine,
validates schema/catalog identity and compatibility, and pins each selected
payload by digest in separate development storage. It does not manufacture
signed admissions, signing keys, release rows, or channel pointers. Release
builds and remote Cloud connections reject the development path. This exception
supersedes blanket draft exclusions only for local development; other
architecture exclusions and browser-based human authentication remain intact.
See [Profile Lab development access and execution](../specifications/PROFILE_LAB.md#development-access-and-unsigned-execution).
