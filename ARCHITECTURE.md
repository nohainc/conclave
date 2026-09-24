# Conclave AX Architecture

Architecture v5 is normative. Architecture v4 is historical only.

> **Projects are collaboration. Workspaces provide execution. Workers provide AI/tool capabilities. Accounts provide external AI identity.**

## Product model
- **Conclave AX** — the main Flutter Web application users interact with.
- **Conclave Cloud** — TypeScript control plane on Cloudflare.
- **Workspace** — one execution environment backed by one enrolled machine/runtime.
- **Worker** — installable AI/tool integration managed automatically by a Workspace.
- **Account** — user-facing name for the internal Credential Profile concept.

## Read first
- [Architecture v5](docs/architecture/ARCHITECTURE_V5.md)
- [v5 source audit](docs/architecture/V5_SOURCE_AUDIT.md)
- [v5 implementation roadmap](docs/roadmaps/ARCHITECTURE_V5_IMPLEMENTATION.md)
- [v5 architecture guardrails](docs/architecture/V5_GUARDRAILS.md)
- [Architecture v4 (historical)](docs/architecture/ARCHITECTURE_V4.md)
- [ADR-008](docs/decisions/ADR-008-project-centric-workspaces.md)
- [ADR-004 (historical)](docs/decisions/ADR-004-host-worker-model.md)
- [ADR-007 (historical)](docs/decisions/ADR-007-product-naming-realtime.md)

Architecture v3 and v4 are historical only.
