# Cloudflare Access for the private alpha

Conclave AX uses Cloudflare Access as the browser authentication boundary during the private alpha. The Flutter web application contains no bearer token or organization identity. The browser signs in to Access, and Access supplies the authenticated identity to the Worker through `ctx.access`.

## Configure Access

1. Deploy the API Worker and the static app on the hostname used by the browser.
2. In Zero Trust, protect `app.conclaveax.com` with an Access application. The policy should allow only the alpha users or groups.
3. Protect every hostname that can reach the API, including any `workers.dev` or preview hostname that is enabled. A bypassed alternate hostname would bypass the application boundary.
4. Enable Worker Access protection for the deployed Worker, or create the equivalent Access application for the custom domain. Access must run before the Worker receives the request.
5. In D1, create an active `organization_memberships` row whose `user_id` is the normalized Access email and whose organization owns the requested projects.
6. Set `CONCLAVE_ACCESS_ORGANIZATION_ID` for a private-alpha deployment with one organization per application. This prevents an identity with multiple memberships from being assigned implicitly to the wrong tenant.

The Worker also checks the Access identity through `ctx.access.getIdentity()` and then performs the organization and project membership checks in D1. It does not trust a client-supplied identity header.

## Machine-to-machine API calls

For CLI and plugin administration calls, create a separate Cloudflare Access
application for the exact route and attach a `Service Auth` policy that
includes the intended Access service token. Send the token credentials as
`CF-Access-Client-Id` and `CF-Access-Client-Secret` headers. Do not put the
secret in Studio or browser assets. The Worker accepts this as a machine
request and still performs its normal workspace and permission checks.

Because a service token has no human email, the plugin-publish route maps the
validated service-token assertion to the configured
`CONCLAVE_PLUGIN_PUBLISHER_EMAIL` workspace member. Keep this mapping explicit
and scoped to the publish route; never use a client-supplied email as the
machine identity.

## Local development

Local development can use the existing anonymous development mode. A development-only bearer token is accepted only when `CONCLAVE_ENVIRONMENT=development`; it is never a browser build input and is rejected by the production authentication path.

For an authenticated local Access simulation, Wrangler supports an `access.dev` configuration with a test identity. Keep that configuration local and do not use it in a production deployment.

## Deployment checks

The app deployment scans the compiled Flutter web directory and fails if server authentication names are present. Flutter receives only `CONCLAVE_API_URL`; `CONCLAVE_AUTH_TOKEN` must never be passed through `--dart-define`.
