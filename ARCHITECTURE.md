# Conclave AX Architecture

Architecture v6 is the historical Workstream/filesystem baseline. Architecture v7 is the active execution architecture for Workspace-owned local Workers and managed adapter processes, defined by ADR-012. Phase 3 removes the V6 configured-Worker compatibility runtime and persistence; earlier V6 architecture documents remain historical references.

## Current v5 model

> **Projects are collaboration. Workspaces provide execution. Workers are configured AI/tool identities. Credential state remains an internal security concern beneath Workers.**

Read:
- [Architecture v5](docs/architecture/ARCHITECTURE_V5.md)
- [v5 guardrails](docs/architecture/V5_GUARDRAILS.md)
- [ADR-008](docs/decisions/ADR-008-project-centric-workspaces.md)

## v6 baseline

v6 keeps the v5 Project/Workspace boundary and introduces Workstream as the unit of collaborative work and mutable state.

> **Projects contain Workstreams. People talk in Discuss. AI work starts only from Work. Each Workstream uses one isolated persistent local working directory on its Primary Workspace, identified only by immutable Project and Workstream IDs.**

Read v6 for the current Workstream/filesystem baseline:
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

Worker Type is adapter/catalog infrastructure. Under the active v7 target, a
Worker is created/authenticated in Conclave Workspace and belongs to exactly one
Workspace. AI Account and Credential Profile are not peer product resources.

Architecture v4 and earlier are historical only.


## Architecture v7 migration target

v7 keeps the v6 Project/Workstream and ID-only working-directory model, but simplifies Worker ownership:

> **Conclave Workspace is the machine runtime. A configured Worker belongs to exactly one Workspace and is created/authenticated locally. Worker Type is a managed adapter; model is configuration. Conclave AX discovers and schedules Workers remotely.**

Read:
- [Architecture v7](docs/architecture/ARCHITECTURE_V7.md)
- [ADR-012](docs/decisions/ADR-012-workspace-owned-local-workers.md)
- [v7 implementation roadmap](docs/roadmaps/ARCHITECTURE_V7_IMPLEMENTATION.md)

The V6 Cloud-created, multi-Workspace Worker backend has been retired. Current product code uses Workspace-owned Workers, safe Cloud inventory, Cloud scheduling authorization, and execution by the owning Workspace. New Worker architecture work follows V7 ownership rules.
