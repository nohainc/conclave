# V2-24 — Same-origin Cloud deployment

## Deployment shape

`app.conclaveax.com` is a Cloudflare Worker Custom Domain serving one application Worker. The Worker owns the `/api/*` surface and falls through to the Flutter web assets for all other paths. The Flutter client uses `/api` as its production base URL; no API hostname is required.

The application Worker binds:

- D1 for structured Conclave state and tenant-scoped read models
- R2 for large artifacts
- Workflows for durable run execution
- Durable Objects for agent gateway and local-runtime connections
- a private service binding to the Forge execution Worker
- static Flutter assets through the `ASSETS` binding

The Forge execution Worker is deployed first because the application Worker references it through a service binding. It is not exposed as a public hostname.

## Request routing

`/api/*` and `/health` run through the Worker first. Other requests are served from the Flutter asset collection, including SPA fallback for browser routes. The API and Studio therefore share origin, cookies, Cloudflare Access policy, and browser security boundaries.

## Deployment prerequisites

The deployment account must already contain the named D1 database and R2 bucket, and the target zone must be managed by Cloudflare. CI supplies the Cloudflare API token and account ID. Production credentials remain Worker secrets; they are not Flutter build variables.

Before the first private-alpha deployment, protect the Custom Domain with Cloudflare Access. The Worker continues to resolve the authenticated Access identity for tenant authorization; anonymous development mode is not enabled in the production configuration.

## Release order

1. Build and test Flutter and TypeScript.
2. Build Flutter web assets.
3. Deploy `conclave-forge-execution`.
4. Deploy `conclave-ax-app` with the same-origin custom domain and bindings.
5. Run `/health`, a static asset smoke test, and an authenticated `/api/studio/snapshot` smoke test.
