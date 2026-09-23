# Architecture v4 Implementation Status

Track progress of the [v4 implementation roadmap](ARCHITECTURE_V4_IMPLEMENTATION.md).

| Phase | Description | Status |
| --- | --- | --- |
| V4-0 | Freeze v4 and establish a green baseline | ✅ Complete |
| V4-1 | Define v4 canonical domain vocabulary | ✅ Complete |
| V4-2 | Redesign Worker manifest/package model | ✅ Complete |
| V4-3 | Define schema-first Host and Worker protocols | ✅ Complete |
| V4-4 | Create clean v4 D1 schema and reset development data | ✅ Complete |
| V4-5 | Rename Cloud execution plane Agent → Host | ✅ Complete |
| V4-6 | Merge Agent App + Agent Engine into Conclave Host | ✅ Complete |
| V4-7 | Convert PluginManager into WorkerManager | ✅ Complete |
| V4-8 | Implement Credential Profiles and local secure storage | ✅ Complete |
| V4-9 | Credential sharing and usage attribution | ✅ Complete |
| V4-10 | Remove configured Worker instances | ✅ Complete |
| V4-11 | Rewrite assignment dispatcher around ResolvedExecutionTarget | ✅ Complete |
| V4-12 | Multi-agent → multi-worker orchestration | ✅ Complete |
| V4-13 | Migrate first-party Worker packages | ✅ Complete |
| V4-14 | Web AI Worker migration | ✅ Complete |
| V4-15 | Simplify Host UI | ✅ Complete |
| V4-16 | Redesign Studio execution UX | ✅ Complete |
| V4-17 | Web-only Studio cleanup | ✅ Complete |
| V4-18 | Authentication and Workspace authorization alignment | ✅ Complete |
| V4-19 | Host desired-state controller | ✅ Complete |
| V4-20 | Session/history isolation | ✅ Complete |
| V4-21 | Forge migration | ✅ Complete |
| V4-22 | Usage, budgets, shared-account accounting | ✅ Complete |
| V4-23 | Security and supply-chain hardening | ✅ Complete |
| V4-24 | Aggressive v3 cleanup | 🚧 In progress |
| V4-25 | Clean-room rebuild and recovery | 🚧 In progress |
| V4-26 | High-quality UI/UX acceptance pass | ✅ Complete |
| V4-27 | Architecture v4 release gate | 🚧 In progress |

## AUTH-0 — Green V4 baseline

Completed 2026-09-23. The architecture guard baseline is clean, CI paths target
`apps/studio` and `apps/host`, and the TypeScript, protocol, Flutter, Dart,
documentation, Wrangler, and security preflight checks pass. Human
authentication migration is intentionally not included in this baseline.

## AUTH-1 — Freeze the long-term authentication architecture

✅ Accepted in [ADR-005](../decisions/ADR-005-authentication-architecture.md).
Better Auth owns human authentication and D1 persistence; Conclave owns all
Workspace, Project, Host, and Credential Profile authorization.

## AUTH-2 — Dedicated Cloud authentication boundary

✅ Better Auth is isolated under `apps/worker/src/auth/`, exposed through an
application-facing `IdentityService`, and mounted at `/api/auth/*`. Existing
authentication paths remain available until a later migration phase removes
them.

## AUTH-3 — Replace the authentication schema cleanly

✅ The clean v4 D1 baseline now maps Better Auth’s core models onto `users`,
`auth_accounts`, `auth_sessions`, and `auth_verifications`. Conclave retains
`users.status`; no compatibility migration was added.

## AUTH-4 — Configure GitHub and Google providers

✅ GitHub is configured first with `user:email`; Google is configured second
with `email` and `profile`. OAuth client secrets remain runtime Cloudflare
secrets. Implicit identity linking is disabled, different-email linking is
disabled, and repository authorization is separate from Conclave sign-in.

## AUTH-5 — Replace `securityContext()` identity resolution

✅ Normal human application APIs resolve the Better Auth session through the
Cloud authentication boundary, then convert that identity into the existing
Conclave Workspace, membership, role, Project, and grant authorization
context. Machine and transitional development paths remain separate; the
legacy human fallback is used only when Better Auth is not configured.

## AUTH-6 — Build the Studio login/logout UX

✅ Studio Web now offers GitHub and Google sign-in through browser redirects to
the Cloud Better Auth boundary, preserves safe deep-link return paths, uses
Better Auth sign-out instead of the legacy Conclave session cookie, and
rechecks the shared browser session when a tab becomes visible again.

## AUTH-7 — Implement first-login provisioning

✅ The first authenticated Conclave request idempotently initializes the
canonical user, creates a deterministic personal Workspace and owner
membership when needed, and exposes unexpired pending invitations without
silently accepting privileged membership.

## AUTH-8 — Make Workspace switching explicit

✅ Studio maintains an explicit active Workspace and sends it as a scoped
request header. Cloud resolves Better Auth’s User first, validates that the
selected Workspace membership is active on every request, and never treats
the browser selection as an authorization claim.

## AUTH-9 — Session and cookie hardening

✅ Better Auth now uses database-backed, HttpOnly browser sessions with
explicit production Secure/SameSite policy, trusted origins, bounded expiry,
refresh, disabled cookie session caching, and standard server-side listing and
revocation endpoints. Same-origin mutation protection no longer depends on
Cloudflare Access service-token exceptions.

## AUTH-10 — Remove Cloudflare Access from application authentication

✅ Production Studio no longer depends on Cloudflare Access for human
authentication. The Worker has no Access identity fallback, Access JWT/header
parsing, Access organization selector, or Access service-token-to-human
mapping. Better Auth is the only production browser authentication path;
Cloudflare Access remains optional infrastructure protection for staging,
administrative, debug, and internal environments.

## AUTH-11 — Delete custom human session infrastructure

✅ Better Auth is now the only human-session implementation. The legacy
`conclave_session` cookie, custom session-token extraction and formatting,
database session verification/revocation, and development human bearer
environment variables were removed. Automated tests use an injected test
authentication adapter, while local development uses the development-only
Better Auth sign-in helper. Bearer credentials remain only in explicit
service-auth paths such as Host, CI, Forge, and connector flows.

## AUTH-13 — Account management

✅ Studio now has a human Account page with the stable Conclave profile,
linked GitHub/Google methods, active Better Auth sessions, and per-session
revocation. Explicit provider linking keeps the Conclave User ID unchanged;
implicit same-email linking remains disabled and different-email linking is
rejected.

## AUTH-14 — Passkeys

✅ Better Auth's official passkey plugin is enabled in the Cloud auth boundary.
Studio Web supports browser-native passkey enrollment, passkey sign-in, and
credential removal. D1 stores only public WebAuthn credential material in the
`passkeys` table; private keys remain on the user's authenticator. Password
authentication is intentionally out of scope.

## AUTH-15 — MFA and step-up authentication

✅ Sensitive-operation policy now identifies Workspace ownership transfer,
Credential Profile sharing, Host revocation, billing/security changes, and API
credential sharing as step-up protected operations. The first enforced route is
Host and Host-enrollment revocation. A successful passkey sign-in creates a
short-lived proof bound to the Better Auth session; mutations fail closed with
HTTP 428 when that proof is missing or stale. TOTP and backup-code support are
reserved for a deliberate follow-up and are not implied by ordinary social or
passkey login.

## AUTH-16 — Enterprise SSO preparation

✅ The identity boundary remains provider-neutral and is documented in
[ADR-006](../decisions/ADR-006-enterprise-federation-preparation.md). Future
OIDC, OAuth2, or SAML support will use Better Auth SSO and resolve to the same
`AuthenticatedIdentity`, Conclave User, and Workspace membership flow. No SSO
plugin or Better Auth Organization authorization was enabled in this phase.

## AUTH-17 — Separate Host pairing from human authentication

✅ Host pairing remains an explicit `host.manage` flow: a human creates a
one-time enrollment, the Host exchanges it, and Cloud issues a separate hashed
machine credential. Enrollment expiry, one-time use, revocation, credential
rotation, Workspace binding, and human-session independence are covered by
Host tests. Logging out or revoking human sessions does not remove enrolled
Hosts; Host revocation independently blocks machine access.

## AUTH-18 — Authentication security test suite

✅ Added explicit security coverage across the Better Auth identity boundary,
Host enrollment, and the shared Conclave authorization package. The suite
covers GitHub and Google entry fixtures, session fixation, expired/revoked and
concurrent sessions, CSRF, OAuth return/state attacks, conservative account
linking, suspended users, removed members, invitation-email mismatch, Workspace
and Project ID substitution, Credential Profile grants, Host authorization,
session revocation, and tenant-scoped Host access.

## AUTH-19 — Audit and observability

✅ Added a secret-free global authentication audit stream for sign-in,
logout/session revocation, provider linking changes, passkey enrollment and
removal, step-up completion, invitation acceptance, and suspicious
authorization denials. Sign-in failure metrics use only an allow-listed
provider, outcome, and coarse reason; OAuth tokens, session tokens, cookies,
passkey material, and raw credentials are excluded.
