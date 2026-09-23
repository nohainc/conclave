# Conclave AX Cloudflare Deployment

## Domain plan

- `conclaveax.com` — public landing page later.
- `app.conclaveax.com` — Conclave AX Studio / Cloud web application.
- `api.conclaveax.com` — reserved for a separately exposed API when production authentication and API separation are complete.
- `docs.conclaveax.com` — documentation later.
- `status.conclaveax.com` — status page later.

## Current deployment

`app.conclaveax.com` is the Studio/Cloud application. It runs the real Studio
application; there is no demo-mode runtime branch. Cloudflare Access must
protect the hostname before production or private-alpha use.

The deployment builds Flutter Web with the planned same-origin API endpoint:

```
flutter build web --release --dart-define=CONCLAVE_API_URL=https://app.conclaveax.com/api
```

Studio uses its normal connection-error state when the API is unavailable. This
is intentional: development should expose integration gaps rather than hide
them behind fake runtime data.

The static application is deployed with Cloudflare Workers Static Assets. SPA fallback is enabled so Flutter web routes resolve to `index.html`.

## GitHub setup

### Better Auth providers

Configure the OAuth applications with these callback URLs:

- `https://app.conclaveax.com/api/auth/callback/github`
- `https://app.conclaveax.com/api/auth/callback/google`

The GitHub application must allow the `user:email` scope. Conclave requests
only identity scopes for sign-in; signing in with GitHub does not grant GitHub
repository access. Repository authorization is a separate future integration.

Set these values in the Worker environment:

- `BETTER_AUTH_URL` — application origin, such as `https://app.conclaveax.com`;
- `GITHUB_CLIENT_ID` — GitHub OAuth client ID;
- `GITHUB_CLIENT_SECRET` — GitHub OAuth client secret;
- `GOOGLE_CLIENT_ID` — Google OAuth client ID;
- `GOOGLE_CLIENT_SECRET` — Google OAuth client secret;
- `BETTER_AUTH_SECRET` — Better Auth encryption/signing secret;
- `BETTER_AUTH_TRUSTED_ORIGINS` — optional comma-separated additional Studio
  origins for local or controlled preview environments.

Store `GITHUB_CLIENT_SECRET`, `GOOGLE_CLIENT_SECRET`, and
`BETTER_AUTH_SECRET` only with Cloudflare Worker secrets (for example,
`wrangler secret put`). Do not commit values to source, Wrangler configuration,
CI files, or browser bundles. Client IDs may be ordinary environment
configuration, but should still be managed per deployment.

Better Auth uses database-backed HttpOnly sessions in `auth_sessions`. The
production policy is a 14-day session with daily refresh, no session data
cookie cache, Secure/HttpOnly/SameSite=Lax cookies, and same-origin mutation
protection. Better Auth's standard session listing and revocation endpoints
remain available under `/api/auth/*`; Studio never receives or stores the
session token.

Repository Settings -> Secrets and variables -> Actions:

- `CLOUDFLARE_ACCOUNT_ID`
- `CLOUDFLARE_API_TOKEN`

Create a Cloudflare API token with only the permissions required to deploy Workers for this account/zone. Do not commit tokens.

Then run:

```
Actions -> Deploy Conclave AX App -> Run workflow
```

The custom-domain route in `infra/cloudflare/app.wrangler.jsonc` targets `app.conclaveax.com`. Because `conclaveax.com` is already on Cloudflare, the Worker custom domain can create/manage the required DNS routing and certificate during deployment.

## Backend deployment gate

Do not expose the API publicly until the release gates in
[`V3_IMPLEMENTATION_STATUS.md`](../roadmaps/V3_IMPLEMENTATION_STATUS.md) are
complete.

Before production backend deployment:

1. verify Cloudflare Access protects the custom domain and the Access identity
   maps to an active Workspace membership;
2. provision production D1/R2 resources; the deployment workflow applies the
   checked-in D1 migrations to `conclave-production`;
3. configure required signing, callback, and other production secrets;
4. run the deployed Forge recovery drill, including Agent restart, Cloud
   restart, network loss, and reviewer timeout;
5. run the external-user security gate, including tenant isolation and
   backup/restore verification;
6. enable API/CI ingress only after the release gates pass.

Cloud owns orchestration and persistence. The Dart Agent Engine provides the
outbound execution channel; Worker Plugins perform model, repository, and tool
operations. The former Local Runtime product concept is not a deployable
service.

At that point the preferred topology is either:

- same origin: `app.conclaveax.com/api/*`, avoiding browser CORS complexity; or
- separated API: `api.conclaveax.com`, with explicit authenticated CORS and CSRF/session design.

The same-origin option should be preferred for the first production release unless there is a concrete reason to separate the API hostname.
