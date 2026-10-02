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

### Before v8 schema freeze

The v8 release is still withheld, so `0001_conclave_v8.sql` remains the
pre-freeze baseline. Whenever it changes, do not deploy the edit through the
normal migration step: Wrangler records applied migrations by filename and
will not notice changed SQL under the existing `0001` name. Re-bootstrap
production on a newly created D1 database instead:

1. Take and protect a fresh export of production data outside the repository.
2. Create a new D1 database and apply the revised `0001` to that empty database.
3. Import/carry forward production data with any required reviewed mapping.
4. Verify aggregate row counts, important parent-child relationships, the
   production binding, and the production acceptance smoke.
5. Cut production over to the new database and retain the prior database until
   the deployment and acceptance checks pass.

Do not edit `0001` in place and continue with the normal deployment workflow;
that workflow cannot re-bootstrap it. Follow the permanent forward-only policy
in [Persistence Contracts](../specifications/PERSISTENCE.md#d1-schema-lifecycle)
once the v8 release record declares schema freeze.

## Required deployment order

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
