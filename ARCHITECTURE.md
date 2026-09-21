# Conclave AX Architecture

> **Normative Architecture:** Architecture v2 is the authoritative architecture for Conclave AX. See [docs/architecture/ARCHITECTURE_V2.md](docs/architecture/ARCHITECTURE_V2.md), [Migration Map](docs/architecture/MIGRATION_V1_TO_V2.md), and [ADR-002](docs/decisions/ADR-002-architecture-v2.md).
> The rule is: *Cloud orchestrates. Agents execute. Plugins integrate. Workers do the actual work. Studio controls and observes.*
> Legacy ConnectionResource direct-execution concepts described below are frozen and superseded by Conclave Agent + Worker Plugins.

## Purpose
Conclave AX is a goal-oriented AI execution and orchestration ecosystem. A user submits a goal through a conversational interface. Conclave AX decomposes that goal into smaller work, delegates work to configured AI models, agents, tools, CI runners, or humans, gathers evidence, independently reviews results, and iterates until completion criteria are met.

## Products
- **Conclave AX Core** — provider-independent orchestration domain and state machine.
- **Conclave AX Studio** — Flutter desktop application.
- **Conclave AX Cloud** — hosted control plane and Flutter web application.
- **Conclave AX Local Runtime** — local TypeScript process with controlled access to repositories, files, shell, tests, Git, and local agents.
- **Conclave AX Forge** — first application built on Core: AI-assisted software development.
- **Conclave AX SDK** — extension and workflow integration surface.
- Future: Runner and additional workflow applications.

Internal code/package namespaces may continue to use `Conclave` and `@conclave/*`; **Conclave AX** is the public product/ecosystem brand.

## High-level topology

```
User
  |
Studio / Cloud UI
  |
Conclave AX Cloud API (Cloudflare Workers)
  |
Conclave AX Core
  |-- Goal / Run / Phase / Task state
  |-- Worker registry
  |-- Execution policy
  |-- Planning / routing
  |-- Verification policy
  |-- Event history
  |
  +-- provider API workers
  +-- Conclave AX Local Runtime
  |      +-- repository / Git / shell / tests
  |      +-- Codex / Claude Code / local agents
  |
  +-- remote agents
  +-- CI/CD systems
  +-- human/manual workers
```

## Worker and connection separation

A **Worker** describes who/what can perform a Task: roles, capabilities, permissions, trust/independence, cost class, and execution limits.

A **Connection** describes how Conclave reaches that Worker: provider API, local agent, remote agent, local model, or manual bridge.

The same model family may appear as several Workers with different roles, connections, permissions, sessions, and billing modes. Core never equates a model/provider name with a Worker identity.

See [Worker Execution and Connection Model](docs/specifications/WORKER_EXECUTION.md).

## Single-worker and multi-worker execution

A Task always has one identity, but its **Execution Policy** determines how many candidate Attempts are created.

Supported policy shapes include:

- `single` — one Worker;
- `parallel` — multiple independent Workers;
- `synthesize` — multiple candidates followed by a synthesis Task;
- `compare_and_select` — multiple candidates followed by an evaluator decision;
- `competitive_implementation` — isolated implementation candidates followed by selection/integration.

This is generic Core behavior, not special Forge logic. Research, design, planning, implementation, review, verification, and future roles use the same Task/Attempt/Artifact/Decision primitives.

See [Multi-Worker Orchestration](docs/specifications/MULTI_WORKER_ORCHESTRATION.md).

## Web/domain topology

```
conclaveax.com
  |
  +-- app.conclaveax.com    Flutter web / Studio
  +-- api.conclaveax.com    reserved for public API separation later
  +-- docs.conclaveax.com   documentation later
  +-- status.conclaveax.com status service later
```

The initial web deployment uses `app.conclaveax.com`. The backend may remain same-origin under `/api` until a separate API hostname is justified.

## Storage
- **D1**: structured system-of-record metadata and orchestration state.
- **R2**: large or unstructured artifacts such as prompts/responses, patches, logs, reports, screenshots, and build outputs.
- **Cloudflare Secrets / encrypted BYOK storage**: credentials.
- Persistence must be hidden behind repository interfaces.

## Core domain
```
Organization
  -> Project
      -> Goal
          -> Run
              -> Phase
                  -> Task
                      -> Attempt / Candidate Attempt(s)
              -> Artifact
              -> Finding
              -> Verification
              -> Decision
              -> Event
```

The normative definitions, state semantics, completion rules, failure classes, and first Forge workflow are in [docs/specifications/DOMAIN_SPECIFICATION.md](docs/specifications/DOMAIN_SPECIFICATION.md). That specification takes precedence over shorthand vocabulary in this overview.

## Fundamental rules
1. Conclave AX manages **Goals**, not prompts.
2. Workers are selected by role/capability, not hard-coded provider.
3. Worker identity is separate from connection/transport and billing mode.
4. One Task may produce one or many candidate Attempts, but only one accepted/combined Task result advances downstream state.
5. Structured contracts are required for machine-to-machine communication.
6. The orchestrator owns workflow state; AI workers propose actions/results.
7. Verification should use independent reviewers and executable evidence where possible.
8. Multi-worker diversity improves coverage; it is not treated as truth by majority vote.
9. Cloud and local execution are separated by an explicit permission boundary.
10. Production deployment must fail closed: no anonymous production API access.
11. The initial system stays intentionally focused until a real Forge vertical slice works end-to-end.
