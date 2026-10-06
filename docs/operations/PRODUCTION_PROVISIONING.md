# Production provisioning

This runbook provisions the Cloudflare resources required by Conclave AX and
Conclave Cloud. It does not contain credentials. Run it from the
repository root with a scoped Cloudflare API token and account ID.

## Resource names

The checked-in Worker configurations expect these production resources:

- D1 database: `conclave-v8-production`;
- R2 bucket: `conclave-artifacts-production`;
- app Worker: `conclave-ax-app`.

Do not reuse development D1 databases or R2 buckets for production.

## Provision storage

```sh
wrangler d1 create conclave-v8-production
wrangler r2 bucket create conclave-artifacts-production
```

The v8 D1 database has already been provisioned and initialized from
`apps/cloud/migrations-v8/0001_conclave_v8.sql`. A private copy of production
rows was imported and checked against the source counts. The previous
`conclave-production` database remains available as a rollback copy; do not
delete it until the v8 app has been deployed and its production checks pass.

### Forward migrations

`0001_conclave_v8.sql` has already been applied to production and is immutable.
Do not edit or re-bootstrap it to deliver schema changes. Add an ordered
forward migration and apply it through the production deployment workflow.
Migration `0002_desktop_auth_multi_audience.sql` rebuilds the desktop auth
tables, preserves their rows and active sessions, and checks before/after row
counts. Follow the forward-only policy in
[Persistence Contracts](../specifications/PERSISTENCE.md#d1-schema-lifecycle).
Migration `0003_workspace_installations.sql` creates stable installation
ownership separately from runtime credentials. It preserves the current owner
and Workspace across runtime rotation and restores released ownership from
audit history. For legacy installation IDs reused across Workspaces, it keeps
the owner and selects the sole non-revoked Workspace; if the full chain is
revoked, it selects the newest historical Workspace. It fails closed on mixed
owners, multiple non-revoked Workspaces, live credentials attached to revoked
Workspaces, or one Workspace mapped to multiple installation IDs.
Migration `0004_workspace_runtime_identity_uniqueness.sql` adds a unique
partial index enforcing one active runtime identity per Workspace. It stops
when legacy data contains duplicate active identities so they can be reviewed
and resolved explicitly before deployment.
Migration `0005_workspace_schema_alignment.sql` aligns the deployed
`execution_workspaces` and `workspace_runtime_identities` table definitions
and indexes with the v8 canonical contract while preserving all existing rows.

## Required deployment order

Before deploying Chat, apply ordered migrations through
`0007_chat_profile_starter_attestation.sql`. Back up the database and pause new
Work submissions while applying the migrations. `0006_chat_workflow_admission.sql`
must run as one atomic migration, never statement by statement: D1 defers foreign
key checks but still performs cascading deletes. The migration saves and restores
affected dependencies and verifies row preservation and foreign-key integrity.
If its schema assertion fails, inspect the actual schema and revise the alignment
to preserve the additional fields/objects before retrying. Do not bypass the guard.
Resume submissions only after migration success and the schema smoke check.

1. Confirm the production app Worker preflight passes:

   ```sh
   node scripts/verify-production-security.mjs
   ```

2. Apply D1 migrations remotely:

   ```sh
   wrangler d1 migrations apply conclave-v8-production \
     --remote --config infra/cloudflare/app.wrangler.jsonc
   ```

3. Deploy the app Worker. It runs Cloud Workflows and dispatches assignments
   through the Workspace Gateway.

The GitHub Actions deployment workflow performs steps 1–3 after Flutter tests
and the browser-secret scan pass.

The current production deployment has completed this sequence. The remote D1
schema is migrated, both Workers are deployed, the app health endpoint returns
`{"ok":true,"environment":"production"}`, and unauthenticated API requests
are rejected with `401`.

## Authentication and secrets

Before production login:

- configure Better Auth GitHub and Google OAuth credentials as Cloudflare
  Worker secrets;
- create or provision Conclave Workspace memberships through the application;
- configure production Cloud, Workspace runtime, and release-signing secrets;
- rotate all values that were used for development or tests.

Never pass these secrets to Flutter through `--dart-define`. The browser uses
the Better Auth HttpOnly session cookie and same-origin `/api` requests.

## Release validation

After deployment, run the
[Workspace desktop lifecycle release validation](WORKSPACE_DESKTOP_LIFECYCLE_RELEASE_VALIDATION.md),
the current Cloud security and Workspace runtime CI acceptance, and the live
provider scenarios recorded in the
[v8 implementation roadmap](../roadmaps/ARCHITECTURE_V8_IMPLEMENTATION.md).
Production evidence must identify the candidate build and deployment and must
not include credentials or provider secrets. Access protection may be enabled
separately for staging, admin, debug, or other internal environments.
