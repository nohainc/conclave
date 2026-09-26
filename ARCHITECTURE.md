# Conclave AX Architecture

**Current architecture:** v7 — Workspace-owned Workers and managed adapter
execution. V7 is the sole current Worker ownership model and remains an active
implementation target until its production release gates pass.

## Product model

> **Projects are collaboration. Workspaces provide machine execution. Workers
> are created and configured locally by their owning Workspace. Cloud
> authorizes and schedules; the owning Workspace executes.**

```text
Conclave AX -> Conclave Cloud -> Conclave Workspace -> Worker adapter process
```

- **Conclave AX** is the human-facing web application for Projects, Workstreams,
  Discuss, Work, Workspace grants, scheduling controls, results and audit.
- **Conclave Cloud** is the authoritative collaboration and scheduling control
  plane. It stores safe Workspace inventory and never receives provider
  credentials.
- **Conclave Workspace** is the persistent desktop runtime and machine security
  boundary. It owns local Workers, credentials, permissions, prerequisites,
  Work Root, adapter admission, process execution and local diagnostics.
- **Worker Type** identifies a managed integration such as Codex, Claude Code,
  an API provider, or Ollama. Models are Worker configuration, not Worker Types.

Each configured Worker belongs to exactly one Workspace. Cloud scheduling state
can enable, disable, or drain that Worker, but cannot make a locally unready
Worker executable or broaden local permissions. Project/Workstream policy and
Workspace grants narrow scheduling eligibility.

## Workstream and execution protocol

Each Workstream has an ID-derived local directory under the Workspace Work
Root. Stateful execution is fenced and restricted to the Workstream Primary
Workspace. Stateless work may use another eligible Workspace only when grants
and policy allow it.

The initial V7 adapter protocol consists of `initialize`, `validate`,
`execute`, `progress`, `result`, `error`, `health`, and `version` messages.
Interactive request/response input is a future versioned extension unless a
production-supported adapter requires it.

## Implementation status

V7 ownership, Cloud scheduling, real V7 assignment execution, and V6 Worker
compatibility retirement are implemented. Production Worker coverage,
adversarial acceptance, and native macOS app update recovery remain open; do
not describe V7 as the implemented baseline until all release gates pass.

## Current references

- [Architecture v7](docs/architecture/ARCHITECTURE_V7.md)
- [ADR-012: Workspace-owned Workers](docs/decisions/ADR-012-workspace-owned-local-workers.md)
- [Applications and product boundaries](docs/architecture/APPLICATIONS.md)
- [Technology stack](docs/architecture/TECH_STACK.md)
- [V7 implementation audit](docs/architecture/V7_IMPLEMENTATION_AUDIT.md)
- [V7 completion plan and release gates](docs/roadmaps/ARCHITECTURE_V7_COMPLETION.md)
- [V7 failure and security acceptance](docs/architecture/V7_FAILURE_RECOVERY_ACCEPTANCE.md)
- [Deployment guidance](docs/deployment/CLOUDFLARE.md)
- [Workspace and adapter release operations](docs/deployment/WORKSPACE_RELEASES.md)
- [Release trust and key rotation](docs/security/RELEASE_TRUST_AND_ROTATION.md)

## Historical documents

Architecture v4–v6 and ADR-009/ADR-010 preserve the decisions made during the
earlier migration. Where their Worker ownership or Cloud binding rules conflict
with ADR-012, ADR-012 and Architecture v7 define current behavior.
