# Conclave AX

**AI execution and orchestration ecosystem where models and agents plan, delegate, build, review, test, and iterate toward verified outcomes.**

Conclave AX coordinates AI Workers and execution Hosts around persistent Goals, Runs, Tasks, verification, and evidence.

Primary domain: **conclaveax.com**

## Architecture

Architecture v4 is normative.

```text
Studio → Cloud → Host → Worker
```

> **Cloud orchestrates. Hosts provide machines. Workers provide AI/tool capabilities. Credential Profiles provide identity and payment context.**

## Applications

- **Conclave AX Studio** — Flutter/Dart web client.
- **Conclave AX Cloud** — TypeScript control plane on Cloudflare.
- **Conclave AX Host** — Flutter/Dart desktop application, one installation per machine.
- **Workers** — installable AI/tool integrations (Codex, Claude Code, OpenAI, Anthropic, Ollama, etc.). Language-independent executable packages; Dart is preferred for first-party Workers where practical.
- **Conclave AX Forge** — first major workflow/application: AI-assisted software development.

## Technology stack

- Flutter + Dart for Studio and Host.
- TypeScript for Cloud.
- Cloudflare Workers + Workflows + Durable Objects.
- Cloudflare D1 for structured Cloud state.
- Cloudflare R2 for artifacts, Worker packages, and release packages.
- Structured JSON/JSON-RPC protocol for Workers.
- GitHub Actions for CI/CD.
- Wrangler for Cloudflare deployment.

## Key concepts

- **Host** — one machine identity. Hosts are not user accounts.
- **Worker** — one installable AI/tool integration. Installed once per Host, supports parallel assignments.
- **Credential Profile** — whose account / API key / subscription is used. Private by default, explicitly shareable.
- **Assignment** — one execution snapshot resolving Host + Worker + Credential Profile + model/config.

Worker processes run as separate child processes under Host supervision. A Worker crash does not crash the Host.

## Read first

- [Architecture](ARCHITECTURE.md)
- [Technology Stack](docs/architecture/TECH_STACK.md)
- [Applications](docs/architecture/APPLICATIONS.md)
- [Architecture v4 Implementation Roadmap](docs/roadmaps/ARCHITECTURE_V4_IMPLEMENTATION.md)
- [Implementation Status](docs/roadmaps/V4_IMPLEMENTATION_STATUS.md)
- [Implementation Roadmap](ROADMAP.md)
- [AI Development Rules](AGENTS.md)

Deployment guidance is in [docs/deployment/CLOUDFLARE.md](docs/deployment/CLOUDFLARE.md).
