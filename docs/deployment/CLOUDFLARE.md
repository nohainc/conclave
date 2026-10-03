# Conclave AX Cloudflare Deployment

Current product and runtime boundaries are documented in [Architecture v8](../architecture/ARCHITECTURE_V8.md).
Operational guidance for signed Workspace and Tool Profile releases is in [Workspace release operations](WORKSPACE_RELEASES.md) and
[Release Trust and Rotation](../security/RELEASE_TRUST_AND_ROTATION.md).

## Domain plan

- `conclaveax.com` — public Astro/static-first website.
- `www.conclaveax.com` — permanent redirect to `conclaveax.com`.
- `app.conclaveax.com` — Conclave AX / Conclave Cloud web application.
- `api.conclaveax.com` — reserved for a separately exposed API when production authentication and API separation are complete.
- `docs.conclaveax.com` — documentation later.
- `status.conclaveax.com` — status page later.

The public site is deployed independently from the authenticated application.
Its production Worker owns only `conclaveax.com` and `www.conclaveax.com`.
It does not handle `/api/*`, `app.conclaveax.com`, Workspace Gateway traffic, or
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
The planned sender-domain migration is to `conclaveax.com`: first enable and
verify that domain for Cloudflare Email Sending, then change
`CONCLAVE_EMAIL_FROM` in the production Wrangler configuration. Until then,
keep the verified current sender. Local development logs the generated link
instead of sending mail.

Store `CONCLAVE_AUTH_GITHUB_CLIENT_SECRET`,
`CONCLAVE_AUTH_GOOGLE_CLIENT_SECRET`, and
`BETTER_AUTH_SECRET` only with Cloudflare Worker secrets (for example,
`wrangler secret put`). Do not commit values to source, Wrangler configuration,
CI files, or browser bundles. These are ultimately secrets on the
`conclave-ax-app` Worker. The production deployment workflow accepts the same
names as GitHub Actions secrets and copies them to the Worker before
deployment. Client IDs may be ordinary environment configuration, but should
still be managed per deployment.

Production Profile publication also requires the `CONCLAVE_RELEASE_PRIVATE_KEY`
GitHub Actions secret and the `CONCLAVE_RELEASE_PUBLISHER`,
`CONCLAVE_RELEASE_SIGNING_KEY_ID`, and `CONCLAVE_RELEASE_TRUST_KEYS_JSON`
GitHub Actions variables. The deployment workflow transfers all four values to
Cloudflare Worker secrets after verifying that the private key matches the
configured public trust root. It stops before deployment if a value is missing
or the key pair does not match. The Cloud Profile signing preflight also checks
the configured key against Cloud's revocation state.

Profile Lab access is controlled by two separate comma-separated user ID
allowlists: `CONCLAVE_PROFILE_ADMIN_USER_IDS` for catalog and draft work, and
`CONCLAVE_PROFILE_RELEASE_MANAGER_USER_IDS` for publication and release
operations. Configure both as GitHub Actions variables used by the deployment
workflow; the workflow syncs them to protected Cloud Worker secrets. A release manager does not receive
catalog or draft administration unless their ID is also in the admin list.

Profile Lab builds default to `https://app.conclaveax.com`. Development builds
can select local Cloud with
`--dart-define=CONCLAVE_CLOUD_URL=http://localhost:8787`; the Cloud connection
settings also allow a local origin override and can reset to the build default.
The app accepts HTTP only for loopback addresses in development builds. Release
builds require HTTPS. Saved Profile Lab sessions are bound to the selected
origin, so switching Cloud targets requires signing in again.

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

Before applying production D1 migrations or deploying Workers, the workflow
runs the v8 clean-schema and Work v1 regression acceptance tests. CI also runs
the v8 runtime and Work v1 end-to-end suites. Failures stop the production
deployment.

After applying production D1 migrations and before deploying
`app.conclaveax.com`, the workflow runs
`scripts/production-workspace-gateway-smoke.mjs --schema-only`. It compares the
stored `CREATE TABLE` definitions and columns for the Workspace and desktop
auth tables with the versioned migration contract. It explicitly requires
both supported audiences in both desktop auth constraints and reports a legacy
single-audience constraint with an instruction to apply pending migrations.
The workflow fails on any missing, unexpected, or drifted contract. This check
only reads schema metadata; it never repairs table definitions.

After deploying `app.conclaveax.com`, the same script runs as a production
acceptance gate. It verifies Profile Lab auth intent creation and cancellation,
validates a disposable Profile Lab audience session, creates a disposable
Workspace management session, registers a uniquely named Workspace, performs
an HTTP/1.1 WebSocket upgrade, sends `workspace.hello`, requires the matching
`workspace.hello.ack`, requests synchronization and requires a correlated
`workspace.sync.result`, verifies the persisted Gateway session, and deletes
the disposable auth, Workspace, and user rows in `finally` cleanup. The runtime
token is generated for that run and is never written to workflow logs or a URL.
A failed schema check, auth request, registration, Gateway exchange, or cleanup
fails the deployment workflow. The smoke uses DML only for disposable rows and
does not change production table definitions.

That automated deployment acceptance does not replace the packaged desktop
lifecycle release run. Before publishing a Workspace desktop release, execute
the ten production scenarios in the
[Workspace desktop lifecycle release validation runbook](../operations/WORKSPACE_DESKTOP_LIFECYCLE_RELEASE_VALIDATION.md),
including native login-item restart and local authentication on a supported
macOS installation. The runbook distinguishes automated CI evidence from
required production-device evidence.

The custom-domain route in `infra/cloudflare/app.wrangler.jsonc` targets `app.conclaveax.com`. Because `conclaveax.com` is already on Cloudflare, the Worker custom domain can create/manage the required DNS routing and certificate during deployment.

## Durable Objects & Database Migrations

### Durable Object migrations

Wrangler applies Durable Object migrations in sequence. Preserve every tag in
`infra/cloudflare/app.wrangler.jsonc` when deploying or re-provisioning; the
earlier tags are retained only because Cloudflare applies migration history
cumulatively. The active runtime binding is `WorkspaceGateway`.

### D1 Database Provisioning
New development databases use the clean v8 schema from
`apps/cloud/migrations-v8`. Apply every ordered migration when initializing
the local database:
```bash
pnpm exec wrangler d1 migrations apply conclave-development --local --config apps/cloud/wrangler.jsonc
```

Production now targets the separately provisioned `conclave-v8-production`
database. It was initialized from the clean v8 baseline, then populated from a
private export of the existing production database. Aggregate row counts and
key parent-child relationships were checked after import. The old
`conclave-production` database remains intact as a rollback copy until the v8
Worker deployment and production checks pass. The v8 migration is a clean
baseline, not an in-place upgrade for a database initialized from an earlier
migration chain. Do not apply it to the old database.

`0001_conclave_v8.sql` has already been applied in production and is immutable.
Schema changes use new ordered forward migrations; the production deployment
workflow applies pending migrations before deploying the Worker. Migration
`0002_desktop_auth_multi_audience.sql` rebuilds the two desktop auth tables,
preserves existing rows and active sessions, validates before/after row counts,
and installs the multi-audience constraints. Never re-bootstrap production to
deliver a schema change. The complete lifecycle policy is in
[Persistence Contracts](../specifications/PERSISTENCE.md#d1-schema-lifecycle).

The `workspace-gateway-schema-regression.test.ts` test constructs a clean
SQLite database by applying the ordered SQL migrations in
`apps/cloud/migrations-v8`, checks critical runtime tables, and exercises the
production Gateway connection, heartbeat, and disconnect statements. The clean
schema must support every SQL statement used by current Cloud runtime code.

The Workspace Gateway Durable Object is authoritative for live connection
state. Workspace online/offline fields and session history are persisted
projections: their writes are queued and logged on failure, but cannot reject
an authenticated connection or interrupt a heartbeat acknowledgement.
Assignment selection checks the owning Gateway's live socket and runtime ID;
it does not trust a stale database online flag. The Durable Object restores
hibernated sockets from its accepted WebSocket attachments before answering
status or dispatch requests.

The app Worker runs durable realtime event cleanup hourly. Event records and
their idempotency keys are retained for 90 days, with up to 10,000 expired
records deleted per run; per-Workspace sequence cursors are retained
indefinitely. Durable events are notifications, so clients refresh current
state from Cloud read APIs after reconnect or a sequence gap. See the
[Persistence Contracts](../specifications/PERSISTENCE.md#durable-realtime-event-retention)
for the retention policy.

## Backend deployment gate

Public production deployment remains gated by the
[current v8 implementation plan](../roadmaps/ARCHITECTURE_V8_IMPLEMENTATION.md).

Before production backend deployment:

1. provision production D1/R2 resources; the deployment workflow applies the
   checked-in D1 migrations to `conclave-v8-production`;
2. configure required signing, callback, and other production secrets;
3. run Workspace desktop lifecycle and Cloud runtime release validations;
4. run the external-user security gate, including tenant isolation and
   backup/restore verification;
5. enable API/CI ingress only after the release gates pass.

Cloud owns orchestration and persistence. Conclave Workspace maintains the
outbound runtime channel; the generic Engine invokes the provider CLI locally.

At that point the preferred topology is either:

- same origin: `app.conclaveax.com/api/*`, avoiding browser CORS complexity; or
- separated API: `api.conclaveax.com`, with explicit authenticated CORS and CSRF/session design.

The same-origin option should be preferred for the first production release unless there is a concrete reason to separate the API hostname.
