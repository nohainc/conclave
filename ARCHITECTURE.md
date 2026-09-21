# Conclave AX Architecture

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
  |-- Planning / routing
  |-- Verification policy
  |-- Event history
  |
  +-- cloud AI providers
  +-- Conclave AX Local Runtime -> repository / shell / tests / coding agents
  +-- CI/CD systems
```

## Web/domain topology

```
conclaveax.com
  |
  +-- app.conclaveax.com   Flutter web / Studio
  +-- api.conclaveax.com   reserved for public API separation later
  +-- docs.conclaveax.com  documentation later
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
1. Conclave AX manages **Goals**, not prompts.
2. Workers are selected by role/capability, not hard-coded provider.
3. Structured contracts are required for machine-to-machine communication.
4. The orchestrator owns workflow state; AI workers propose actions/results.
5. Verification should use independent reviewers and executable evidence where possible.
6. Cloud and local execution are separated by an explicit permission boundary.
7. Production deployment must fail closed: no anonymous production API access.
8. The initial system stays intentionally focused until a real Forge vertical slice works end-to-end.
