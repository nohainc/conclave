# Engineering Foundation

Phase 1 establishes a small monorepo with one shared Flutter application and provider-independent TypeScript packages.

## Workspace layout

- `packages/core` — provider-independent Core types and domain helpers.
- `packages/protocol` — versioned runtime-validated machine-to-machine contracts.
- `packages/persistence` — D1/R2-neutral records, repository interfaces, and run reconstruction.
- Core worker registry — configurable capability/role/permission routing independent of provider.
- Core task graph — validated dependencies with deterministic retries, budgets, timeouts, cancellation, and reopening.
- Core verification gate — isolated reviews, policy-based evidence, blocking findings, and fix/re-review loops.
- Forge workflow — research, plan, implementation, independent review, correction, tests, verification, and reporting.
- Durable Worker execution — Workflow checkpoints, idempotency, pause/resume, restart, and external event waits.
- `packages/local-runtime` — local execution boundary and environment configuration.
- Local Runtime operation boundary — outbound approved repository operations with bounded structured evidence.
- `apps/worker` — Cloudflare Worker API entrypoint and smoke tests.
- `apps/flutter_app` — one Flutter codebase for Studio and web UI.

The Flutter app keeps platform-specific behavior behind `PlatformServices`. Later desktop, web, and local-runtime integrations should add implementations behind that interface instead of branching through UI code.

## Checks

From the repository root:

```text
pnpm install
pnpm check
pnpm --filter @conclave/worker check:startup
```

For Flutter:

```text
cd apps/flutter_app
flutter pub get
flutter analyze
flutter test
```

GitHub Actions runs both check suites on pushes to `main` and pull requests. The Worker uses `wrangler.jsonc`, a current compatibility date, `nodejs_compat`, observability, and generated Cloudflare types when bindings are introduced. Secrets belong in local `.dev.vars` or the CI secret store; `.env.example` contains non-secret defaults only.
