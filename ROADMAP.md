# Conclave AX Roadmap

Architecture v6 is the implemented Workstream/filesystem baseline. Architecture
v7 is the active Worker/runtime migration. Its **desktop vertical slice is now
implemented**, but architecture convergence and production release gates remain
open before v7 becomes the implemented baseline.

Current execution direction:

```text
Conclave AX -> Conclave Cloud -> Conclave Workspace -> local Worker -> adapter process
```

Projects are the collaboration boundary. Workspaces provide machine execution.
Configured Workers are created/authenticated locally in Conclave Workspace,
belong to exactly one Workspace, and synchronize only safe inventory/readiness
to Cloud. Workers never connect directly to Conclave Cloud.

## Active work

The detailed architecture roadmap is:

[Architecture v7 Implementation Roadmap](docs/roadmaps/ARCHITECTURE_V7_IMPLEMENTATION.md)

The ordered remaining work and release gates are:

[Architecture v7 Completion Plan](docs/roadmaps/ARCHITECTURE_V7_COMPLETION.md)

The current implementation audit is:

[V7 Implementation Audit](docs/architecture/V7_IMPLEMENTATION_AUDIT.md)

The completion sequence is intentionally:

1. finish V7 Cloud scheduling state and candidate model;
2. prove the real V7 end-to-end path;
3. remove V6 Worker binding/API/persistence compatibility;
4. replace shared-secret release trust with asymmetric signing;
5. automate first-party adapter releases;
6. finish production Worker coverage and live acceptance;
7. harden failure/security/reconciliation behavior;
8. finish macOS background/update/diagnostics UX;
9. declare v7 the implemented baseline only after all release gates pass.

## Historical roadmaps

Earlier implementation history remains available in:
- [Architecture v5 Implementation Roadmap](docs/roadmaps/ARCHITECTURE_V5_IMPLEMENTATION.md)
- [Architecture v4 Implementation Roadmap](docs/roadmaps/ARCHITECTURE_V4_IMPLEMENTATION.md)
- [v4 Implementation Status](docs/roadmaps/V4_IMPLEMENTATION_STATUS.md)
