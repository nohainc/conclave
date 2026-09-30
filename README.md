# Conclave AX

**AI execution and orchestration ecosystem where models and AI tools plan, delegate, build, review, test, and iterate toward verified outcomes.**

Conclave AX coordinates AI Workers across execution Workspaces around persistent Projects, Chats, Goals, Runs, Tasks, verification, and evidence.

Primary domain: **conclaveax.com**

## Architecture

Architecture v7 is the current Worker ownership and execution architecture. V7 ownership, Cloud scheduling, end-to-end assignment execution, V6 compatibility retirement, and asymmetric release trust are implemented. V7 remains an active implementation target until production Worker, adversarial security/recovery, and native app-update release gates pass.

```text
Conclave AX -> Conclave Cloud -> Conclave Workspace -> Worker executable -> provider CLI
```

> **Projects are collaboration. Workspaces provide execution. Workers are configured AI/tool identities. Credential/package state is managed beneath Workers.**

## Applications

- **Conclave AX** — the primary Flutter Web application.
- **Conclave Cloud** — TypeScript control plane on Cloudflare.
- **Conclave Workspace** — the native desktop execution/security application installed once per normal machine/OS-user installation; macOS is the first release target.
- **Workers** — fixed local execution slots such as ChatGPT and Gemini. Worker Runtime v2 implements each first-party Worker as an independently versioned standalone Dart console executable that owns its provider CLI integration.
- **Conclave AX Forge** — AI-assisted software-development workflow built on the platform.

## Technology stack

- Flutter + Dart for the Conclave AX web application and Conclave Workspace desktop application.
- TypeScript for Conclave Cloud.
- Cloudflare Workers + Workflows + Durable Objects.
- Cloudflare D1 for structured state.
- Cloudflare R2 for artifacts, Worker packages, and releases.
- Better Auth for human authentication.
- Versioned Local Worker Protocol between Workspace and standalone Worker processes. The current Node-backed implementation is 2.x; Worker Runtime v2 introduces Local Worker Protocol 3.0 for native Worker executables with Worker version/state compatibility, probe, execute, progress/result/error, and no provider tokens/account secrets on the wire.
- GitHub Actions for CI/CD.
- Wrangler for Cloudflare deployment.

## Key concepts

- **Project** — the collaboration, history, and authorization boundary.
- **Workspace** — one machine-backed execution environment owned by one User.
- **Worker Type** — stable product integration type. The first-party v1 catalog is `chatgpt` and `gemini`.
- **Worker** — one Workspace-owned local product slot implemented by an independently versioned Worker executable; provider CLI/session details remain local.
- **Workspace Grant** — explicit permission for a Project to use a Workspace.
- **Credential state** — local authentication metadata/readiness owned by Conclave Workspace; provider secrets never enter Conclave Cloud.
- **Workstream working directory** — one persistent local directory resolved as `<work-root>/<project-id>/<workstream-id>`; names and Workspace ID never participate in path identity.
- **Assignment** — one immutable execution snapshot resolving Project + Workstream + Workspace + configured Worker + Worker Type + model/config and authorized credential state.

Worker executables run as separate per-assignment child processes under Conclave Workspace supervision and start provider CLI children as needed. Workers do not authenticate directly to Conclave Cloud.

## Read first

- [Architecture](ARCHITECTURE.md)
- [Current architecture](ARCHITECTURE.md)
- [Technology Stack](docs/architecture/TECH_STACK.md)
- [Applications](docs/architecture/APPLICATIONS.md)
- [Workstream working-directory roadmap](docs/roadmaps/WORKSTREAM_WORKING_DIRECTORIES.md)
- [Architecture v7](docs/architecture/ARCHITECTURE_V7.md)
- [ADR-012: Workspace-owned local Workers](docs/decisions/ADR-012-workspace-owned-local-workers.md)
- [v7 implementation roadmap](docs/roadmaps/ARCHITECTURE_V7_IMPLEMENTATION.md)
- [v7 implementation audit](docs/architecture/V7_IMPLEMENTATION_AUDIT.md)
- [v7 completion plan](docs/roadmaps/ARCHITECTURE_V7_COMPLETION.md)
- [Workspace desktop auth and dual-transport plan](docs/roadmaps/WORKSPACE_AUTH_TRANSPORT_IMPLEMENTATION.md)
- [Workspace desktop lifecycle plan](docs/roadmaps/WORKSPACE_DESKTOP_LIFECYCLE_IMPLEMENTATION.md)
- [ADR-017: Standalone Dart Worker executables](docs/decisions/ADR-017-standalone-dart-worker-executables.md)
- [Worker Runtime v2 architecture](docs/architecture/WORKER_RUNTIME_V2.md)
- [Worker Runtime v2 implementation plan](docs/roadmaps/WORKER_RUNTIME_V2_IMPLEMENTATION.md)
- [Workspace and Worker release operations](docs/deployment/WORKSPACE_RELEASES.md)
- [Release trust and key rotation](docs/security/RELEASE_TRUST_AND_ROTATION.md)
- [AI Development Rules](AGENTS.md)

Deployment guidance is in [docs/deployment/CLOUDFLARE.md](docs/deployment/CLOUDFLARE.md). V6 architecture documents and ADR-009/ADR-010 remain historical; ADR-012 governs current Worker ownership.
