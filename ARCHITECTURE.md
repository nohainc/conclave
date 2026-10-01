# Conclave AX Architecture

**Current architecture target:** Architecture v8 — generic CLI Worker Engine +
signed Tool Profiles.

**v8 release declaration:** Withheld pending the acceptance gates in the
[v8 implementation plan](docs/roadmaps/ARCHITECTURE_V8_IMPLEMENTATION.md).

Architecture v8 is the current architecture. It preserves the historical v7
Workspace/Worker ownership model and Work v1 orchestration while replacing one
native provider Worker binary per integration with one isolated generic Engine
and Cloud-managed official Profile releases.

~~~text
Conclave AX
-> Conclave Cloud
-> Conclave Workspace
-> CLI Worker Engine
-> signed Tool Profile
-> provider CLI
~~~

## Product model

> **Projects and Workstreams define collaboration and how logical Workers are
> used. Workspaces provide machine execution. Workers remain stable user-facing
> AI/tool identities. Engine/Profile implementation stays beneath the Worker.**

- **Conclave AX** — human web application for Projects, Workstreams, Discuss,
  Work, Workspace grants, Worker bindings, results, and audit.
- **Conclave Cloud** — collaboration/scheduling plane and official logical
  Worker/Profile registry. It never receives provider credentials.
- **Conclave Workspace** — persistent desktop machine/security supervisor. It
  owns local Work Root, permissions, logical Worker readiness, Profile
  verification/cache, Engine process supervision, cancellation and diagnostics.
- **CLI Worker Engine** — one standalone Dart console executable used by all
  supported local CLI Workers.
- **Tool Profile** — signed immutable provider integration configuration
  interpreted by the Engine.
- **Provider CLI** — local tool such as Codex or Antigravity `agy`; provider
  authentication and subscription/API mode remain local to that tool.

Initial logical Worker mappings:

~~~text
ChatGPT -> chatgpt-codex Profile -> Codex CLI
Gemini  -> gemini-antigravity Profile -> agy
~~~

Workstream configuration continues to target `chatgpt` and `gemini`, not
Engine/Profile releases.

## Work v1

Conclave owns five canonical Steps:

~~~text
Research
Plan
Implement
Test
Verify
~~~

and five built-in Workflows:

~~~text
Direct
Research
Plan & Implement
Implement & Verify
Full Cycle
~~~

Users do not create arbitrary Workflow graphs or edit Conclave's internal Step
Prompt Profiles. They select a built-in Workflow, bind logical Workers to
Direct/Steps, optionally select models/add instructions, and submit Work.

Every Work Request snapshots its Workflow, bindings, models, instructions,
attachment references, and prompt-profile versions.

Architecture v8 changes only the local Worker implementation beneath those
logical Worker bindings.

## Protocol boundaries

Conclave has three product/runtime boundaries:

~~~text
AX <-> Cloud
Human Product Protocol

Cloud <-> Workspace
Workspace Runtime Protocol

Workspace <-> CLI Worker Engine
Local Worker Protocol 4.0
~~~

Provider CLI communication is private to Engine + Tool Profile.

The protocols share domain IDs but never credentials or wire envelopes.

## Local Worker Protocol 4.0

Protocol 4.0 identifies:

~~~text
logical Worker Type
Engine version
Profile definition/release
Profile schema version
provider tool name/version
capabilities
~~~

and supports:

~~~text
initialize
probe(passive|live)
execute
progress
result
error
~~~

Provider tokens, provider session IDs, arbitrary Cloud-supplied executable paths,
and shell commands are never protocol fields.

## Tool Profile trust

Profiles are configuration but treated as code.

Official Profile releases are:
- immutable;
- signed;
- schema validated;
- versioned independently;
- fixture tested;
- promoted through Draft/Testing/Beta/Stable;
- rollbackable/revocable;
- read-only to normal users in v8.

A Profile cannot enable shell execution, arbitrary scripts, unrestricted
environment inheritance, or bypass Workspace/Engine security limits.

The normative schema is
[Tool Profile v1](docs/specifications/TOOL_PROFILE_V1.md).

## Runtime version layers

Diagnostics distinguish:

~~~text
Workspace version
CLI Worker Engine version
Tool Profile definition/release
provider CLI version
provider model when explicit
~~~

Most normal provider CLI compatibility changes should require only a Profile
release. Engine updates are reserved for generic runtime/schema capabilities or
Engine bugs.

## Current implementation status

Architecture v8 is the accepted implementation target. Current main already has
the v7/v2 out-of-process Dart Worker runtime and the constrained Work v1
orchestration, which provide the migration baseline.

Until the v8 release gates pass, do not claim the provider-specific ChatGPT and
Gemini Dart binaries have been removed or that all assignments execute through
the generic Engine/Profile path.

The ordered migration is defined in:

[Architecture v8 Implementation Plan](docs/roadmaps/ARCHITECTURE_V8_IMPLEMENTATION.md)

## Current references

- [Architecture v8](docs/architecture/ARCHITECTURE_V8.md)
- [ADR-018: Generic CLI Worker Engine and Tool Profiles](docs/decisions/ADR-018-generic-cli-worker-engine-and-tool-profiles.md)
- [Tool Profile v1](docs/specifications/TOOL_PROFILE_V1.md)
- [Architecture v8 Implementation](docs/roadmaps/ARCHITECTURE_V8_IMPLEMENTATION.md)
- [Work v1 Contract](docs/specifications/WORK_V1_CONTRACT.md)
- [First-party Worker Catalog v1](docs/specifications/FIRST_PARTY_WORKER_CATALOG_V1.md)
- [Protocol Boundaries](docs/architecture/PROTOCOL_BOUNDARIES.md)
- [Technology Stack](docs/architecture/TECH_STACK.md)
- [Workspace release operations](docs/deployment/WORKSPACE_RELEASES.md)
- [Release trust and rotation](docs/security/RELEASE_TRUST_AND_ROTATION.md)

## Historical predecessors

Architecture v7 is the historical baseline; Worker Runtime v2 is its
process-boundary predecessor. They remain evidence for:
- Workspace ownership;
- process isolation;
- local provider credentials;
- process-tree cancellation;
- provider-neutral local protocol;
- durable provider-session mapping.

ADR-017 is superseded by ADR-018 for first-party CLI implementation. New normal
CLI integrations must use v8 Engine + Profile architecture rather than adding a
new provider-specific native Worker binary.
