# Conclave AX

**AI execution and orchestration ecosystem where models and AI tools plan,
delegate, build, review, test, and iterate toward verified outcomes.**

Primary domain: **conclaveax.com**

## Architecture

Architecture v8 is the active implementation target.

~~~text
Conclave AX
-> Conclave Cloud
-> Conclave Workspace
-> generic CLI Worker Engine
-> signed Tool Profile
-> provider CLI
~~~

The first v8 logical Workers remain:

~~~text
ChatGPT -> chatgpt-codex Profile -> Codex CLI
Gemini  -> gemini-antigravity Profile -> agy
~~~

Users continue to interact with ChatGPT/Gemini Workers. Engine/Profile versions
are implementation details shown only in Advanced Diagnostics.

## Applications

- **Conclave AX** — Flutter Web application for Projects, Workstreams, Discuss
  and Work.
- **Conclave Cloud** — TypeScript/Cloudflare collaboration, scheduling,
  Workspace Gateway, Worker catalog and Profile release control plane.
- **Conclave Workspace** — native Flutter/Dart desktop execution/security
  supervisor.
- **CLI Worker Engine** — one standalone Dart console executable used for
  supported local CLI Workers.
- **Tool Profiles** — signed immutable official provider integration releases.
- **Conclave AX Forge** — AI-assisted software-development workflow built on
  the platform.

## Work v1

Conclave defines fixed canonical Steps:

~~~text
Research
Plan
Implement
Test
Verify
~~~

and built-in Workflows:

~~~text
Direct
Research
Plan & Implement
Implement & Verify
Full Cycle
~~~

Workstreams bind those Steps to logical Workers. Users do not build arbitrary
Workflow graphs or edit Conclave's internal orchestration prompts in v1.

## Technology stack

- Flutter + Dart for AX and Conclave Workspace.
- TypeScript for Conclave Cloud.
- Dart AOT for the generic CLI Worker Engine.
- Cloudflare Workers + Workflows + Durable Objects.
- Cloudflare D1 for structured state.
- Cloudflare R2 where release/artifact payload storage is appropriate.
- Better Auth for human authentication.
- Local Worker Protocol 4.0 between Workspace and CLI Worker Engine.
- Signed Tool Profile v1 releases for provider CLI behavior.
- GitHub Actions for CI/CD.
- Wrangler for Cloudflare deployment.

## Key concepts

- **Project** — collaboration/history/authorization boundary.
- **Workstream** — persistent unit of work and local working directory.
- **Workspace** — one machine-backed execution environment.
- **Worker Type** — stable product AI/tool identity such as `chatgpt` or
  `gemini`.
- **CLI Worker Engine** — generic local executor/interpreter; not a user-facing
  Worker.
- **Tool Profile** — signed provider integration configuration used by the
  Engine.
- **Provider CLI** — local tool that owns provider authentication/session/billing
  mode.
- **Workspace Grant** — Project authorization to use a Workspace.
- **Assignment** — immutable execution snapshot resolving Project + Workstream +
  logical Worker + runtime evidence.

## Runtime trust boundary

Workspace supervises Engine processes but does not implement provider behavior.

The Engine:
- loads a Workspace-admitted signed Profile;
- finds/probes the provider CLI;
- launches it without a shell;
- parses its bounded output;
- enforces session continuity;
- normalizes progress/result/error.

Profiles cannot disable Engine/Workspace security invariants.

Provider secrets never enter Conclave Cloud.

## Read first

- [Architecture](ARCHITECTURE.md)
- [Architecture v8](docs/architecture/ARCHITECTURE_V8.md)
- [ADR-018: Generic CLI Worker Engine and Tool Profiles](docs/decisions/ADR-018-generic-cli-worker-engine-and-tool-profiles.md)
- [Tool Profile v1](docs/specifications/TOOL_PROFILE_V1.md)
- [Architecture v8 implementation plan](docs/roadmaps/ARCHITECTURE_V8_IMPLEMENTATION.md)
- [Work v1 contract](docs/specifications/WORK_V1_CONTRACT.md)
- [First-party Worker catalog v1](docs/specifications/FIRST_PARTY_WORKER_CATALOG_V1.md)
- [Protocol Boundaries](docs/architecture/PROTOCOL_BOUNDARIES.md)
- [Technology Stack](docs/architecture/TECH_STACK.md)
- [Workspace release operations](docs/deployment/WORKSPACE_RELEASES.md)
- [Release trust and rotation](docs/security/RELEASE_TRUST_AND_ROTATION.md)
- [AI Development Rules](AGENTS.md)

New CLI integrations use the generic Engine and official signed Tool Profiles.
See [Architecture](ARCHITECTURE.md) and the [v8 implementation roadmap](docs/roadmaps/ARCHITECTURE_V8_IMPLEMENTATION.md) for current contracts and release gates.
