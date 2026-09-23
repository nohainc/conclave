# Cloudflare Access for non-production environments

Cloudflare Access is optional infrastructure protection for staging,
administrative, debug, and other internal environments. It is not the human
authentication boundary for production Studio. Production users sign in through
Better Auth at `/api/auth/*`, and Conclave resolves that session to its own
Workspace and authorization model.

## Configure Access

1. Deploy the Worker and static app on the internal hostname.
2. In Zero Trust, create an Access application for that internal hostname.
3. Protect only the intended staging, admin, debug, or internal routes and
   keep the policy scoped to the appropriate operators.
4. Keep production Studio public and verify that disabling this Access
   application does not affect Better Auth login or Conclave authorization.

## Machine-to-machine API calls

Machine and CI calls use their explicitly scoped Conclave credentials. Access
service tokens may protect separate internal administration routes, but they
are not converted into human identities and are not accepted by the
production application-auth path.

## Local development

Local development can use the existing anonymous development mode. A
development-only bearer token is accepted only when
`CONCLAVE_ENVIRONMENT=development`; it is never a browser build input and is
rejected by the production authentication path.

For an authenticated local Access simulation, Wrangler supports an `access.dev`
configuration with a test identity. Keep that configuration local and do not
use it as a substitute for Better Auth in production.

## Deployment checks

The app deployment scans the compiled Flutter web directory and fails if server
authentication names are present. Flutter receives only `CONCLAVE_API_URL`;
`CONCLAVE_AUTH_TOKEN` must never be passed through `--dart-define`.
