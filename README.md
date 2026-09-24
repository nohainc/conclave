# Conclave AX

**AI execution and orchestration ecosystem where models and AI tools plan, delegate, build, review, test, and iterate toward verified outcomes.**

Conclave AX coordinates AI Workers across execution Workspaces around persistent Projects, Chats, Goals, Runs, Tasks, verification, and evidence.

Primary domain: **conclaveax.com**

## Architecture

Architecture v5 is normative. Architecture v4 is historical only.

```text
Conclave AX -> Conclave Cloud -> Workspace -> Worker
```

> **Projects are collaboration. Workspaces provide execution. Workers provide AI/tool capabilities. Accounts decide whose external AI credentials are used.**

## Applications

- **Conclave AX** — the primary Flutter Web application.
- **Conclave Cloud** — TypeScript control plane on Cloudflare.
- **Workspace** — one execution environment backed by one enrolled machine/runtime.
- **Workers** — installable AI/tool integrations such as Codex, Claude Code, OpenAI and Anthropic.
- **Conclave AX Forge** — AI-assisted software-development workflow built on the platform.

## Technology stack

- Flutter + Dart for Conclave AX and the Workspace runtime application.
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
- **Worker** — one installable AI/tool integration. Installed once per Workspace and usable by eligible assignments.
- **Workspace Grant** — explicit permission for a Project to use a Workspace.
- **Account** — user-facing name for a Credential Profile: whose external AI account/API key/subscription is used.
- **Assignment** — one immutable execution snapshot resolving Project + Workspace + Worker + Account + model/config.

Worker processes run as separate child processes under Workspace runtime supervision. Workers do not authenticate directly to Conclave Cloud.

## Read first

- [Architecture](ARCHITECTURE.md)
- [Architecture v5](docs/architecture/ARCHITECTURE_V5.md)
- [Technology Stack](docs/architecture/TECH_STACK.md)
- [Applications](docs/architecture/APPLICATIONS.md)
- [v5 implementation roadmap](docs/roadmaps/ARCHITECTURE_V5_IMPLEMENTATION.md)
- [AI Development Rules](AGENTS.md)

Deployment guidance is in [docs/deployment/CLOUDFLARE.md](docs/deployment/CLOUDFLARE.md).
