# Conclave AX Cloudflare Deployment

## Domain plan

- `conclaveax.com` — public landing page later.
- `app.conclaveax.com` — Conclave AX Studio / Cloud web application.
- `api.conclaveax.com` — reserved for a separately exposed API when production authentication and API separation are complete.
- `docs.conclaveax.com` — documentation later.
- `status.conclaveax.com` — status page later.

## Current development deployment

`app.conclaveax.com` is the current development/staging web application. It runs the real Studio application; there is no demo-mode runtime branch.

The deployment builds Flutter Web with the planned same-origin API endpoint:

```
flutter build web --release --dart-define=CONCLAVE_API_URL=https://app.conclaveax.com/api
```

Until the real API is deployed at that endpoint, Studio is expected to show its normal connection-error state. This is intentional: development should expose real integration gaps rather than hide them behind fake runtime data.

The static application is deployed with Cloudflare Workers Static Assets. SPA fallback is enabled so Flutter web routes resolve to `index.html`.

## GitHub setup

Repository Settings -> Secrets and variables -> Actions:

- `CLOUDFLARE_ACCOUNT_ID`
- `CLOUDFLARE_API_TOKEN`

Create a Cloudflare API token with only the permissions required to deploy Workers for this account/zone. Do not commit tokens.

Then run:

```
Actions -> Deploy Conclave AX App -> Run workflow
```

The custom-domain route in `infra/cloudflare/app.wrangler.jsonc` targets `app.conclaveax.com`. Because `conclaveax.com` is already on Cloudflare, the Worker custom domain can create/manage the required DNS routing and certificate during deployment.

## Backend production deployment

Do not expose the current API publicly until the integration milestone is complete.

Before production backend deployment:

1. remove development-only anonymous access;
2. replace the single static bearer-token identity with production authentication;
3. scope every Studio query by organization/project/run;
4. resolve Workflow instance ID vs Conclave run ID consistently;
5. make Workflow completion depend on actual Forge completion rather than successful dispatch;
6. configure production D1/R2 resources and apply migrations;
7. configure provider/BYOK secrets;
8. verify Local Runtime outbound transport and permissions;
9. run a real two-model end-to-end Forge test;
10. enable API/CI ingress only after security tests pass.

At that point the preferred topology is either:

- same origin: `app.conclaveax.com/api/*`, avoiding browser CORS complexity; or
- separated API: `api.conclaveax.com`, with explicit authenticated CORS and CSRF/session design.

The same-origin option should be preferred for the first production release unless there is a concrete reason to separate the API hostname.
