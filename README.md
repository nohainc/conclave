# Conclave AX

**AI execution and orchestration ecosystem where models and AI tools plan, delegate, build, review, test, and iterate toward verified outcomes.**

Conclave AX coordinates AI Workers across execution Hosts around persistent Projects, Chats, Goals, Runs, Tasks, verification, and evidence.

Primary domain: **conclaveax.com**

## Architecture

Architecture v4 is normative.

```text
Conclave AX -> Conclave Cloud -> Conclave Host -> Worker
```

> **Cloud orchestrates. Hosts provide machines. Workers provide AI/tool capabilities. Accounts decide whose external AI credentials are used.**

## Applications

- **Conclave AX** — the primary Flutter Web application.
- **Conclave Cloud** — TypeScript control plane on Cloudflare.
- **Conclave Host** — Flutter/Dart desktop application, one installation per machine.
- **Workers** — installable AI/tool integrations such as Codex, Claude Code, OpenAI and Anthropic.
- **Conclave AX Forge** — AI-assisted software-development workflow built on the platform.

## Technology stack

- Flutter + Dart for Conclave AX and Conclave Host.
- TypeScript for Conclave Cloud.
- Cloudflare Workers + Workflows + Durable Objects.
- Cloudflare D1 for structured state.
- Cloudflare R2 for artifacts, Worker packages, and releases.
- Better Auth for human authentication.
- Structured local Worker protocol between Host and Worker processes.
- GitHub Actions for CI/CD.
- Wrangler for Cloudflare deployment.

## Key concepts

- **Host** — one machine identity. Hosts are not human user accounts.
- **Worker** — one installable AI/tool integration. Installed once per Host and usable by many assignments.
- **Account** — user-facing name for a Credential Profile: whose external AI account/API key/subscription is used.
- **Assignment** — one immutable execution snapshot resolving Host + Worker + Account + model/config.

Worker processes run as separate child processes under Host supervision. Workers do not authenticate directly to Conclave Cloud.

## Read first

- [Architecture](ARCHITECTURE.md)
- [Technology Stack](docs/architecture/TECH_STACK.md)
- [Applications](docs/architecture/APPLICATIONS.md)
- [Post-auth v4 roadmap](docs/roadmaps/POST_AUTH_V4_IMPLEMENTATION.md)
- [Implementation Status](docs/roadmaps/V4_IMPLEMENTATION_STATUS.md)
- [AI Development Rules](AGENTS.md)

Deployment guidance is in [docs/deployment/CLOUDFLARE.md](docs/deployment/CLOUDFLARE.md).
