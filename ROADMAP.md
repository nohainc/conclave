# Conclave AX Roadmap

Architecture v5 is normative. Architecture v4 is historical only.

The active roadmap is:

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
