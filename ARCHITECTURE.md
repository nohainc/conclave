# Conclave AX Architecture

Architecture v5 is the currently implemented normative architecture.

Architecture v6 is the proposed next architecture for collaborative Workstreams and isolated execution.

## Current v5 model

> **Projects are collaboration. Workspaces provide execution. Workers are configured AI/tool identities. Credential state remains an internal security concern beneath Workers.**

Read:
- [Architecture v5](docs/architecture/ARCHITECTURE_V5.md)
- [v5 guardrails](docs/architecture/V5_GUARDRAILS.md)
- [ADR-008](docs/decisions/ADR-008-project-centric-workspaces.md)

## Proposed v6

v6 keeps the v5 Project/Workspace boundary and introduces Workstream as the unit of collaborative work and mutable state.

> **Projects contain Workstreams. People talk in Discuss. AI work starts only from Work. Stateful work uses one isolated Workstream checkout on one Primary Workspace.**

Read v6 before new collaboration/execution architecture work:
- [Architecture v6](docs/architecture/ARCHITECTURE_V6.md)
- [v6 source audit](docs/architecture/V6_SOURCE_AUDIT.md)
- [v6 implementation roadmap](docs/roadmaps/ARCHITECTURE_V6_IMPLEMENTATION.md)
- [ADR-009](docs/decisions/ADR-009-workstreams-isolated-execution.md)
- [ADR-010](docs/decisions/ADR-010-configured-worker-execution-model.md)
- [Configured Worker implementation roadmap](docs/roadmaps/CONFIGURED_WORKER_EXECUTION.md)

Architecture v4 and earlier are historical only.
