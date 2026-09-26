# Conclave AX

**AI execution and orchestration ecosystem where models and AI tools plan, delegate, build, review, test, and iterate toward verified outcomes.**

Conclave AX coordinates AI Workers across execution Workspaces around persistent Projects, Chats, Goals, Runs, Tasks, verification, and evidence.

Primary domain: **conclaveax.com**

## Architecture

Architecture v6 is the Workstream/filesystem baseline. Architecture v7 is the active Worker/runtime implementation target; its desktop vertical slice is implemented while Cloud-model cleanup, production trust, acceptance, and desktop maturity remain in progress.

```text
Conclave AX -> Conclave Cloud -> Conclave Workspace -> configured Worker -> adapter process
```

> **Projects are collaboration. Workspaces provide execution. Workers are configured AI/tool identities. Credential/package state is managed beneath Workers.**

## Applications

- **Conclave AX** — the primary Flutter Web application.
- **Conclave Cloud** — TypeScript control plane on Cloudflare.
- **Conclave Workspace** — the native desktop execution/security application installed once per normal machine/OS-user installation; macOS is the first release target.
- **Workers** — locally configured executable AI/tool identities such as “Codex Personal” or “Claude Review”; each belongs to exactly one Workspace and uses one Worker Type adapter.
- **Conclave AX Forge** — AI-assisted software-development workflow built on the platform.

## Technology stack

- Flutter + Dart for the Conclave AX web application and Conclave Workspace desktop application.
- TypeScript for Conclave Cloud.
- Cloudflare Workers + Workflows + Durable Objects.
- Cloudflare D1 for structured state.
- Cloudflare R2 for artifacts, Worker packages, and releases.
- Better Auth for human authentication.
- Structured local Worker protocol between Workspace runtime and Worker processes.
- GitHub Actions for CI/CD.
- Wrangler for Cloudflare deployment.

## Key concepts

- **Project** — the collaboration, history, and authorization boundary.
- **Workspace** — one machine-backed execution environment owned by one User.
- **Worker Type** — signed integration adapter definition such as Codex, Antigravity, Claude Code, OpenAI API, or Gemini API.
- **Worker** — one locally configured AI/tool identity on exactly one Workspace, with one Worker Type, local credential state, defaults, capabilities, and model policy.
- **Workspace Grant** — explicit permission for a Project to use a Workspace.
- **Credential state** — local authentication metadata/readiness owned by Conclave Workspace; provider secrets never enter Conclave Cloud.
- **Workstream working directory** — one persistent local directory resolved as `<work-root>/<project-id>/<workstream-id>`; names and Workspace ID never participate in path identity.
- **Assignment** — one immutable execution snapshot resolving Project + Workstream + Workspace + configured Worker + Worker Type + model/config and authorized credential state.

Adapter processes run as separate per-assignment child processes under Conclave Workspace supervision. Workers do not authenticate directly to Conclave Cloud.

## Read first

- [Architecture](ARCHITECTURE.md)
- [Architecture v5](docs/architecture/ARCHITECTURE_V5.md)
- [Technology Stack](docs/architecture/TECH_STACK.md)
- [Applications](docs/architecture/APPLICATIONS.md)
- [v5 implementation roadmap](docs/roadmaps/ARCHITECTURE_V5_IMPLEMENTATION.md)
- [Configured Worker model](docs/decisions/ADR-010-configured-worker-execution-model.md)
- [Configured Worker implementation roadmap](docs/roadmaps/CONFIGURED_WORKER_EXECUTION.md)
- [Workstream working-directory decision](docs/decisions/ADR-011-workstream-working-directories.md)
- [Workstream working-directory roadmap](docs/roadmaps/WORKSTREAM_WORKING_DIRECTORIES.md)
- [Architecture v7](docs/architecture/ARCHITECTURE_V7.md)
- [ADR-012: Workspace-owned local Workers](docs/decisions/ADR-012-workspace-owned-local-workers.md)
- [v7 implementation roadmap](docs/roadmaps/ARCHITECTURE_V7_IMPLEMENTATION.md)
- [v7 implementation audit](docs/architecture/V7_IMPLEMENTATION_AUDIT.md)
- [v7 completion plan](docs/roadmaps/ARCHITECTURE_V7_COMPLETION.md)
- [AI Development Rules](AGENTS.md)

Deployment guidance is in [docs/deployment/CLOUDFLARE.md](docs/deployment/CLOUDFLARE.md).
