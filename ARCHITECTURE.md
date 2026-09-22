# Conclave AX Architecture

Architecture v4 is the implementation target.

> **Cloud orchestrates. Hosts provide machines. Workers provide AI/tool capabilities. Credential Profiles decide whose account is used.**

## Product model
- **Conclave Studio** — Flutter Web user interface.
- **Conclave Cloud** — TypeScript control plane on Cloudflare.
- **Conclave Host** — one Flutter/Dart installation per machine.
- **Worker** — installable AI/tool integration managed automatically by Host.
- **Credential Profile** — user/workspace account identity used by Worker assignments.

## Read first
- [Architecture v4](docs/architecture/ARCHITECTURE_V4.md)
- [v4 source audit](docs/architecture/V4_SOURCE_AUDIT.md)
- [v4 implementation roadmap](docs/roadmaps/ARCHITECTURE_V4_IMPLEMENTATION.md)
- [ADR-004](docs/decisions/ADR-004-host-worker-model.md)

Architecture v3 is historical during migration.
