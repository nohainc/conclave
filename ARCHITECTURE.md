# Conclave Architecture

## Purpose
Conclave is a goal-oriented AI orchestration ecosystem. A user submits a goal through a conversational interface. Conclave decomposes that goal into smaller work, delegates work to configured AI models, agents, tools, CI runners, or humans, gathers evidence, independently reviews results, and iterates until completion criteria are met.

## Products
- **Conclave Core** — provider-independent orchestration domain and state machine.
- **Conclave Studio** — Flutter desktop application.
- **Conclave Cloud** — hosted control plane and Flutter web application.
- **Conclave Local Runtime** — local TypeScript process with controlled access to repositories, files, shell, tests, Git, and local agents.
- **Conclave Forge** — first application built on Core: AI-assisted software development.
- Future: Runner, SDK, CI integrations.

## High-level topology

```
User
  |
Studio / Cloud UI
  |
Conclave Cloud API (Cloudflare Workers)
  |
Conclave Core
  |-- Goal / Run / Phase / Task state
  |-- Worker registry
  |-- Planning / routing
  |-- Verification policy
  |-- Event history
  |
  +-- cloud AI providers
  +-- Conclave Local Runtime -> repository / shell / tests / coding agents
  +-- CI/CD systems
```

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
                      -> Attempt
              -> Conversation / Model Call
              -> Artifact
              -> Finding
              -> Verification
              -> Decision
      -> Event
```

The normative definitions, state semantics, completion rules, failure classes, and first Forge workflow are in [docs/specifications/DOMAIN_SPECIFICATION.md](docs/specifications/DOMAIN_SPECIFICATION.md). That specification takes precedence over shorthand vocabulary in this overview.

## Fundamental rules
1. Conclave manages **Goals**, not prompts.
2. Workers are selected by role/capability, not hard-coded provider.
3. Structured contracts are required for machine-to-machine communication.
4. The orchestrator owns workflow state; AI workers propose actions/results.
5. Verification should use independent reviewers and executable evidence where possible.
6. Cloud and local execution are separated by an explicit permission boundary.
7. The initial system is intentionally small: two AI workers, one Forge workflow, D1 + R2, Workers + Workflows.
