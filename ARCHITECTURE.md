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

> **Projects contain Workstreams. People talk in Discuss. AI work starts only from Work. Each Workstream uses one isolated persistent local working directory on its Primary Workspace, identified only by immutable Project and Workstream IDs.**

Read v6 before new collaboration/execution architecture work:
- [Architecture v6](docs/architecture/ARCHITECTURE_V6.md)
- [v6 source audit](docs/architecture/V6_SOURCE_AUDIT.md)
- [v6 implementation roadmap](docs/roadmaps/ARCHITECTURE_V6_IMPLEMENTATION.md)
- [ADR-009](docs/decisions/ADR-009-workstreams-isolated-execution.md)
- [ADR-010](docs/decisions/ADR-010-configured-worker-execution-model.md)
- [Configured Worker implementation roadmap](docs/roadmaps/CONFIGURED_WORKER_EXECUTION.md)
- [ADR-011](docs/decisions/ADR-011-workstream-working-directories.md)
- [Workstream working-directory roadmap](docs/roadmaps/WORKSTREAM_WORKING_DIRECTORIES.md)

### EW-0 execution vocabulary

The configured-Worker model is accepted and its vocabulary is frozen:

```text
Execution
├── Workspaces
└── Workers
```

Worker Type is catalog/infrastructure. Worker is the configured user resource
with one logical external AI identity and zero or more Workspace bindings.
AI Account and Credential Profile remain internal credential/readiness terms;
they are not equal first-class product resources.

Architecture v4 and earlier are historical only.
