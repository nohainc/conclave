# Conclave AX Roadmap

Architecture v5 remains the implemented baseline. Architecture v7 is the active migration target; v6 remains the current Workstream/filesystem baseline until the v7 Worker vertical slice is proven.

The prior implementation roadmap is:

[Architecture v5 Implementation Roadmap](docs/roadmaps/ARCHITECTURE_V5_IMPLEMENTATION.md)

The v4 migration and post-authentication roadmaps remain useful as implementation history:

[Architecture v4 Implementation Roadmap](docs/roadmaps/ARCHITECTURE_V4_IMPLEMENTATION.md)

Track completed v4/authentication work in:

[v4 Implementation Status](docs/roadmaps/V4_IMPLEMENTATION_STATUS.md)

Current execution model:

```text
Conclave AX -> Conclave Cloud -> Workspace -> Worker
```

Projects are the collaboration boundary. A Project uses a Workspace only through an explicit Workspace Grant. Execution is the product area for Workspaces and configured Workers; credential/account records remain internal beneath Workers.

Workers never connect directly to Conclave Cloud.

The active architecture migration is [Architecture v7](docs/roadmaps/ARCHITECTURE_V7_IMPLEMENTATION.md). Follow its delivery sequence and preserve the current executable path until local Worker creation, inventory sync, scheduling, and adapter execution work end to end.
