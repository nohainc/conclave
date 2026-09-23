# Conclave AX Cloudflare Deployment

## Domain plan

- `conclaveax.com` — public Astro/static-first website.
- `www.conclaveax.com` — permanent redirect to `conclaveax.com`.
- `app.conclaveax.com` — Conclave AX / Conclave Cloud web application.
- `api.conclaveax.com` — reserved for a separately exposed API when production authentication and API separation are complete.
- `docs.conclaveax.com` — documentation later.
- `status.conclaveax.com` — status page later.

The public site is deployed independently from the authenticated application.
Its production Worker owns only `conclaveax.com` and `www.conclaveax.com`.
It does not handle `/api/*`, `app.conclaveax.com`, Host Gateway traffic, or
Better Auth callbacks. PR previews use a separate temporary Workers name with
no production custom-domain routes; merging to `main` deploys the production
site through `.github/workflows/deploy-site-production.yml`.

The public site's production config provisions HTTPS custom domains for the
apex and `www` hostnames. The site Worker returns a permanent 308 redirect
from `www` to the apex, Astro emits trailing-slash routes, serves a static
`404.html`, revalidates HTML, and marks fingerprinted `/_astro/` assets as
immutable for one year. These rules apply only to the public-site Worker.

## Current deployment

`app.conclaveax.com` is the Conclave AX/Cloud application. It runs the real
application; there is no demo-mode runtime branch. Production Conclave AX is a
public login application whose human sessions are handled by Better Auth.
Cloudflare Access is optional for staging, administrative, debug, and other
internal environments; it is not an application authentication dependency.

The deployment builds Flutter Web with the planned same-origin API endpoint:

```
flutter build web --release --dart-define=CONCLAVE_API_URL=https://app.conclaveax.com/api
```

Conclave AX uses its normal connection-error state when the API is unavailable. This
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
- `CONCLAVE_AUTH_GITHUB_CLIENT_ID` — GitHub OAuth client ID;
- `CONCLAVE_AUTH_GITHUB_CLIENT_SECRET` — GitHub OAuth client secret;
- `CONCLAVE_AUTH_GOOGLE_CLIENT_ID` — Google OAuth client ID;
- `CONCLAVE_AUTH_GOOGLE_CLIENT_SECRET` — Google OAuth client secret;
- `BETTER_AUTH_SECRET` — Better Auth encryption/signing secret;
- `BETTER_AUTH_TRUSTED_ORIGINS` — optional comma-separated additional Conclave AX
  origins for local or controlled preview environments.

The production Worker also uses Cloudflare Email Service for email verification
and password reset. The current configured sender is
`auth@auth.earthuc.com`, under the enabled `auth.earthuc.com` sending domain.
If Conclave later enables Email Sending directly for `conclaveax.com`, update
`CONCLAVE_EMAIL_FROM` in the production Wrangler configuration. Local
development logs the generated link instead of sending mail.

Store `CONCLAVE_AUTH_GITHUB_CLIENT_SECRET`,
`CONCLAVE_AUTH_GOOGLE_CLIENT_SECRET`, and
`BETTER_AUTH_SECRET` only with Cloudflare Worker secrets (for example,
`wrangler secret put`). Do not commit values to source, Wrangler configuration,
CI files, or browser bundles. These are ultimately secrets on the
`conclave-ax-app` Worker. The production deployment workflow accepts the same
names as GitHub Actions secrets and copies them to the Worker before
deployment. Client IDs may be ordinary environment configuration, but should
still be managed per deployment.

Better Auth uses database-backed HttpOnly sessions in `auth_sessions`. The
production policy is a 14-day session with daily refresh, no session data
cookie cache, Secure/HttpOnly/SameSite=Lax cookies, and same-origin mutation
protection. Better Auth's standard session listing and revocation endpoints
remain available under `/api/auth/*`; Conclave AX never receives or stores the
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

1. provision production D1/R2 resources; the deployment workflow applies the
   checked-in D1 migrations to `conclave-production`;
2. configure required signing, callback, and other production secrets;
3. run the deployed Forge recovery drill, including Host restart, Cloud
   restart, network loss, and reviewer timeout;
4. run the external-user security gate, including tenant isolation and
   backup/restore verification;
5. enable API/CI ingress only after the release gates pass.

Cloud owns orchestration and persistence. The Conclave Host provides the
outbound execution channel; Workers perform model, repository, and tool
operations. The former Local Runtime product concept is not a deployable
service.

At that point the preferred topology is either:

- same origin: `app.conclaveax.com/api/*`, avoiding browser CORS complexity; or
- separated API: `api.conclaveax.com`, with explicit authenticated CORS and CSRF/session design.

The same-origin option should be preferred for the first production release unless there is a concrete reason to separate the API hostname.
