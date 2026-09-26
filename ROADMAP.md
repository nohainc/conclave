# Conclave AX Roadmap

Architecture v6 is the historical Workstream/filesystem baseline. Architecture
v7 is the active Worker/runtime architecture. Its desktop vertical slice and
V6 compatibility retirement are implemented; production release gates remain
open before v7 becomes the declared implemented baseline.

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

Phases 1–3 are implemented: Cloud-owned V7 scheduling state and inventory,
real V7 end-to-end assignment execution, and retirement of V6 Worker
compatibility APIs, scheduler fallback, and persistence.

The remaining sequence is intentionally:

1. **Phase 4:** replace shared-secret release trust with asymmetric signing and
   automate release publication;
2. **Phase 5:** finish production Worker coverage and live-provider acceptance;
3. **Phase 6:** harden failure/recovery/security behavior;
4. **Phase 7:** finish macOS background/update/diagnostics UX;
5. **Phase 8:** declare v7 the implemented baseline only after all release
   gates pass.

The Phase 2 behavioral E2E migration-safety gate passes and remains a regression test for the V7 execution path.

## Historical roadmaps

Earlier implementation history remains available in:
- [Architecture v5 Implementation Roadmap](docs/roadmaps/ARCHITECTURE_V5_IMPLEMENTATION.md)
- [Architecture v4 Implementation Roadmap](docs/roadmaps/ARCHITECTURE_V4_IMPLEMENTATION.md)
- [v4 Implementation Status](docs/roadmaps/V4_IMPLEMENTATION_STATUS.md)
