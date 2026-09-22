# Production provisioning

This runbook provisions the Cloudflare resources required by the Architecture
v3 app and Forge Workers. It does not contain credentials. Run it from the
repository root with a scoped Cloudflare API token and account ID.

## Resource names

The checked-in Worker configurations expect these production resources:

- D1 database: `conclave-production`;
- R2 bucket: `conclave-artifacts-production`;
- Forge Worker service: `conclave-forge-execution`;
- app Worker: `conclave-ax-app`.

Do not reuse development D1 databases or R2 buckets for production.

## Provision storage

```sh
wrangler d1 create conclave-production
wrangler r2 bucket create conclave-artifacts-production
```

If the resources already exist, keep the existing IDs and names. The app
configuration uses the resource names; D1 migrations are applied by the deploy
workflow.

## Required deployment order

1. Confirm the production preflight passes for both Wrangler configurations:

   ```sh
   node scripts/verify-production-security.mjs
   node scripts/verify-production-security.mjs \
     apps/worker/forge-execution.wrangler.jsonc
   ```

2. Apply D1 migrations remotely:

   ```sh
   wrangler d1 migrations apply conclave-production \
     --remote --config infra/cloudflare/app.wrangler.jsonc
   ```

3. Deploy the Forge Worker, then the app Worker. The app binds to the Forge
   service by name and serves the Flutter web assets at the custom domain.

The GitHub Actions deployment workflow performs steps 1–3 after Flutter tests
and the browser-secret scan pass.

## Authentication and secrets

Before private-alpha access:

- protect `app.conclaveax.com` and every alternate API hostname with
  Cloudflare Access;
- create active Workspace memberships matching normalized Access identities;
- set `CONCLAVE_ACCESS_ORGANIZATION_ID` when one private-alpha Workspace is
  selected;
- configure `CONCLAVE_CI_INGEST_TOKEN`;
- configure `CONCLAVE_FORGE_CALLBACK_TOKEN`;
- configure production plugin, Agent, and backup/signing secrets;
- rotate all values that were used for development or tests.

Never pass these secrets to Flutter through `--dart-define`. The browser uses
the Access session and same-origin `/api` requests.

## Release validation

After deployment, execute the [Forge recovery drill](FORGE_RECOVERY_DRILL.md)
and the tenant/security integration suite. The P0–P25 objective is not closed
until Agent restart, Cloud restart, network loss, reviewer timeout, Cloudflare
Access, backup/restore, and cross-tenant isolation have been exercised against
the deployed system.
