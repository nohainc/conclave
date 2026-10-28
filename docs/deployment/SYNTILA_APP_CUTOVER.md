# Syntila production cutover — 2026-10-28

The production application is deployed at https://syntila.app using Worker
`syntila-app`, version `3ca099b5-998e-4240-80b6-28cfc510e910`.
The public site remains at https://conclaveax.com, using `syntila-site`, version
`a4834def-8cac-4249-97bc-839dcafc78cc`; its app links now target Syntila.

The new D1 database is `syntila`, ID
`6130c425-59e2-4ec7-b7bd-d3fe8a8ea6a7`, in EEUR. All 90 migrations are applied;
there are zero user accounts and no foreign-key violations. No old production
rows were copied. Artifacts use `syntila-artifacts-production`. The former app,
database and artifact bucket remain intact.

Authentication audiences, token prefixes, local paths, markers, package root,
remaining filenames and deployment scripts use Syntila. Generated Dart protocol
bindings were refreshed. Existing real GitHub repository URLs and marketing,
email and download addresses on conclaveax.com remain valid. The future
syntila.com domain is not configured.

## Verification

- Production Worker dry run and both production deployments succeeded.
- HTTPS app index, `/health` and `/api/auth/get-session` returned HTTP 200.
  Health reported `production`; the unauthenticated session was null.
- Public DNS resolvers returned Cloudflare addresses for syntila.app. The
  machine's cached negative DNS result required `curl --resolve` for live
  checks immediately after provisioning; TLS certificate validation stayed on.
- The deployed D1 schema gate passed: 17 required tables, 14 critical table
  definitions and seven indexes. The gate now accounts for the existing
  parallel-slots migration; its 13 regression tests passed.
- App validation passed: formatting, analysis and 1,113 tests. Release Flutter
  web compilation passed.
- Site component validation passed: Astro diagnostics, build and four tests.
- Profile Lab component validation passed: analysis and 74 tests.
- Cloud validation initially passed 1,230 tests with six timeouts. All 53
  tests in the three affected files passed when rerun with one worker.
- Deployment/migration script tests passed (66 tests across 14 files).
- Workspace validation found eight failures. After fixing macOS signing of
  copied Engine aliases, all 28 tests in the seven affected files passed.
  Workspace Service compiled, started headlessly and stopped cleanly.
- Branding, documentation links, protocol generation and production-security
  checks passed. Broader Engine validation still encounters process timeouts;
  real provider tests require separate opt-in credentials/environment.

This scope covers the renamed auth contracts, deployment configuration, fresh
schema and direct desktop consumers. It does not certify a newly signed desktop
installer release or real provider execution.

## Operational impact

Recreate accounts and reconnect desktop clients to the new origin. No old
sessions or registrations are transferred. Local paths and marker names now
use Syntila; existing local Conclave state is not copied by this cutover.
Email/password registration uses the existing authorized conclaveax.com email
senders. No test email was sent. GitHub and Google sign-in remain disabled until
new-origin OAuth callbacks and the corresponding Worker secrets are configured.
