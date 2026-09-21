# Conclave AX

**AI execution and orchestration ecosystem where models and agents plan, delegate, build, review, test, and iterate toward verified outcomes.**

Conclave AX coordinates AI Workers and execution hosts around persistent Goals, Runs, Tasks, verification, and evidence.

Primary domain: **conclaveax.com**

## Applications

- **Conclave AX Studio** — Flutter/Dart web + desktop client.
- **Conclave AX Cloud** — TypeScript control plane on Cloudflare.
- **Conclave AX Agent App** — Flutter/Dart desktop host-management UI.
- **Conclave AX Agent Engine** — Dart AOT native background process.
- **Worker Plugins** — language-independent executable integrations; Dart is preferred for first-party plugins where practical.
- **Conclave AX Forge** — first major workflow/application: AI-assisted software development.

## Technology stack

- Flutter + Dart for Studio and Agent App.
- Dart native executable for Agent Engine.
- TypeScript for Cloud.
- Cloudflare Workers + Workflows + Durable Objects.
- Cloudflare D1 for structured Cloud state.
- Cloudflare R2 for artifacts, plugin packages, and release packages.
- JSON-RPC/structured process protocol for Worker Plugins.
- GitHub Actions for CI/CD.
- Wrangler for Cloudflare deployment.

## Architecture rule

> **Cloud orchestrates. Agent Engine executes. Worker Plugins integrate. Workers do the work. Flutter apps control and observe.**

The Agent App and Agent Engine are separate OS processes so closing the UI never stops active work.

Worker Plugins run as separate executable processes and may be written in Dart, TypeScript/Node.js, Rust, Python, Go, or another language.

## Read first

- [Architecture](ARCHITECTURE.md)
- [Technology Stack](docs/architecture/TECH_STACK.md)
- [Applications](docs/architecture/APPLICATIONS.md)
- [Migration to Architecture v3](docs/architecture/MIGRATION_TO_V3.md)
- [Implementation Roadmap](ROADMAP.md)
- [AI Development Rules](AGENTS.md)

Deployment guidance is in [docs/deployment/CLOUDFLARE.md](docs/deployment/CLOUDFLARE.md).
