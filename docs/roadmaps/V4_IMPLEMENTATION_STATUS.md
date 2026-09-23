# Architecture v4 Implementation Status

Track progress of the [v4 implementation roadmap](ARCHITECTURE_V4_IMPLEMENTATION.md).

| Phase | Description | Status |
| --- | --- | --- |
| V4-0 | Freeze v4 and establish a green baseline | ✅ Complete |
| V4-1 | Define v4 canonical domain vocabulary | ✅ Complete |
| V4-2 | Redesign Worker manifest/package model | ✅ Complete |
| V4-3 | Define schema-first Host and Worker protocols | ✅ Complete |
| V4-4 | Create clean v4 D1 schema and reset development data | ✅ Complete |
| V4-5 | Rename Cloud execution plane Agent → Host | ✅ Complete |
| V4-6 | Merge Agent App + Agent Engine into Conclave Host | ✅ Complete |
| V4-7 | Convert PluginManager into WorkerManager | ✅ Complete |
| V4-8 | Implement Credential Profiles and local secure storage | ✅ Complete |
| V4-9 | Credential sharing and usage attribution | ✅ Complete |
| V4-10 | Remove configured Worker instances | ✅ Complete |
| V4-11 | Rewrite assignment dispatcher around ResolvedExecutionTarget | ✅ Complete |
| V4-12 | Multi-agent → multi-worker orchestration | ✅ Complete |
| V4-13 | Migrate first-party Worker packages | ✅ Complete |
| V4-14 | Web AI Worker migration | ✅ Complete |
| V4-15 | Simplify Host UI | ✅ Complete |
| V4-16 | Redesign Studio execution UX | ✅ Complete |
| V4-17 | Web-only Studio cleanup | ✅ Complete |
| V4-18 | Authentication and Workspace authorization alignment | ✅ Complete |
| V4-19 | Host desired-state controller | ✅ Complete |
| V4-20 | Session/history isolation | ✅ Complete |
| V4-21 | Forge migration | ✅ Complete |
| V4-22 | Usage, budgets, shared-account accounting | ✅ Complete |
| V4-23 | Security and supply-chain hardening | ✅ Complete |
| V4-24 | Aggressive v3 cleanup | 🚧 In progress |
| V4-25 | Clean-room rebuild and recovery | 🚧 In progress |
| V4-26 | High-quality UI/UX acceptance pass | ✅ Complete |
| V4-27 | Architecture v4 release gate | 🚧 In progress |

## AUTH-0 — Green V4 baseline

Completed 2026-09-23. The architecture guard baseline is clean, CI paths target
`apps/studio` and `apps/host`, and the TypeScript, protocol, Flutter, Dart,
documentation, Wrangler, and security preflight checks pass. Human
authentication migration is intentionally not included in this baseline.

## AUTH-1 — Freeze the long-term authentication architecture

✅ Accepted in [ADR-005](../decisions/ADR-005-authentication-architecture.md).
Better Auth owns human authentication and D1 persistence; Conclave owns all
Workspace, Project, Host, and Credential Profile authorization.

## AUTH-2 — Dedicated Cloud authentication boundary

✅ Better Auth is isolated under `apps/worker/src/auth/`, exposed through an
application-facing `IdentityService`, and mounted at `/api/auth/*`. Existing
authentication paths remain available until a later migration phase removes
them.
