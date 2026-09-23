# Conclave AX Architecture

Architecture v4 is normative.

> **Cloud orchestrates. Hosts provide machines. Workers provide AI/tool capabilities. Credential Profiles provide identity and payment context.**

## Product model
- **Conclave AX** — the main Flutter Web application users interact with.
- **Conclave Cloud** — TypeScript control plane on Cloudflare.
- **Conclave Host** — one Flutter/Dart installation per machine.
- **Worker** — installable AI/tool integration managed automatically by Host.
- **Account** — user-facing name for the internal Credential Profile concept.

## Read first
- [Architecture v4](docs/architecture/ARCHITECTURE_V4.md)
- [v4 source audit](docs/architecture/V4_SOURCE_AUDIT.md)
- [v4 implementation roadmap](docs/roadmaps/ARCHITECTURE_V4_IMPLEMENTATION.md)
- [v4 implementation status](docs/roadmaps/V4_IMPLEMENTATION_STATUS.md)
- [Post-auth v4 roadmap](docs/roadmaps/POST_AUTH_V4_IMPLEMENTATION.md)
- [ADR-004](docs/decisions/ADR-004-host-worker-model.md)
- [ADR-007](docs/decisions/ADR-007-product-naming-realtime.md)

Architecture v3 is historical only.
