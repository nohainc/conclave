# Conclave AX Architecture

Architecture v3 is the authoritative architecture.

> **Cloud orchestrates. Agent Engine executes. Worker Plugins integrate. Workers do the work. Flutter apps control and observe.**

## Applications

- **Conclave AX Studio** — Flutter/Dart web + desktop client.
- **Conclave AX Cloud** — TypeScript on Cloudflare.
- **Conclave AX Agent App** — Flutter/Dart desktop UI.
- **Conclave AX Agent Engine** — Dart AOT native background process.
- **Worker Plugins** — language-independent executable integrations; Dart is preferred for first-party plugins when practical.

## Read first

- [Architecture v3](docs/architecture/ARCHITECTURE_V3.md)
- [Technology Stack](docs/architecture/TECH_STACK.md)
- [Migration to v3](docs/architecture/MIGRATION_TO_V3.md)
- [Implementation Roadmap](docs/roadmaps/ARCHITECTURE_V3_IMPLEMENTATION.md)

The repository keeps only current Architecture v3 guidance in active documentation.
