# Architecture v3 implementation status

This is an evidence index for `ARCHITECTURE_V3_IMPLEMENTATION.md`. P26 is
intentionally excluded from this status document.

## Current state

P0 through P22 have implementation and automated-test coverage in the current
tree. P23 through P25 have substantial implementation and green subsystem
tests, but their final release-level exit proof still requires the external
runtime checks listed below.

| Phase | Evidence in the repository | Status |
| --- | --- | --- |
| P0 | CI workflow, TypeScript checks, Flutter checks, Dart checks, native compilation, and Studio web build | Implemented and locally verified |
| P1 | Architecture v3, application, technology, migration, and ADR documentation | Implemented |
| P2 | Canonical protocol schemas, generated bindings, compatibility fixtures, and validation tests | Implemented |
| P3–P7 | Dart Engine, Agent App, authenticated IPC, Cloud Gateway, journal, reconciliation, and reconnect tests | Implemented |
| P8–P11 | Plugin protocol/manager, deterministic plugin, runtime capability controls, and output/process limits | Implemented |
| P12–P15 | Codex, Claude, API, and interactive web-worker plugins | Implemented and tested |
| P16–P20 | Agent UI, signed self-update, macOS distribution, Studio cleanup, authentication, and tenant controls | Implemented and tested |
| P21 | Tenant-scoped Agent/Plugin/Worker management, update announcement endpoint, Gateway delivery, and Studio update control | Implemented and tested |
| P22 | Execution policies, distributed ensembles, synthesis/selection, cost routing, and acceptance tests | Implemented and tested |
| P23 | Real fixture Forge pipeline, Agent Engine execution, Cloud assignment boundary, evidence, and durable Forge reconciliation | Implemented; external restart/network/timeout drill remains |
| P24 | No tracked TypeScript Agent application or imports; automated `agent:retirement-check`; CI targets Dart Engine and Flutter Agent App | Implemented; `RuntimeConnection`/`ConnectionResource` remain only as transitional architecture for the later deletion gate |
| P25 | Signed packages/releases, revocation, permissions, sandboxed process boundaries, secret redaction, backups, audit export, threat model, and security tests | Implemented; production security gate remains |

## Remaining proof work before the P0–P25 objective can be closed

1. Run the P23 Forge scenario against deployed Cloud + Agent processes while
   exercising Agent restart, Cloud restart, network loss, and reviewer timeout.
2. Run the P25 external-user gate with production signing keys, dependency
   scanning, rate limits, Cloudflare Access, backup/restore drill, and the
   tenant-isolation suite.
3. Perform the final repository-wide P24 legacy-reference audit and record its
   output.

These are verification gates, not a replacement for implementation. P26, the
broader v0.1 release gate, is intentionally deferred.
