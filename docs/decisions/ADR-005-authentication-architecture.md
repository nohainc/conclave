# ADR-005: Better Auth for human authentication

**Status:** Accepted  
**Date:** 2026-09-23

## Context

Conclave currently has overlapping human-authentication paths: custom
`auth_sessions`, a `conclave_session` cookie, development bearer/anonymous
fallbacks, and Cloudflare Access identity mapping. That makes it unclear which
system authenticates a person and which system authorizes their Conclave
actions.

V4 needs one durable human identity boundary while preserving Conclave's
domain-specific authorization model. Human identity, Host machine identity,
and AI account identity must remain separate:

```text
Human       -> Better Auth session
Host        -> Conclave machine credential
AI account  -> Credential Profile
```

## Decision

Use Better Auth as Conclave's long-term human authentication engine. Mount it
in Conclave Cloud at `/api/auth/*` and persist its authentication records in
Cloudflare D1 using Better Auth's supported D1 integration.

The initial sign-in methods are email/password plus these social identity
providers:

- email/password;
- GitHub;
- Google.

Studio Web uses same-origin, Secure, HttpOnly cookie sessions issued and
managed by Better Auth. Browser application code does not read session tokens,
place them in local storage, or manufacture Conclave session cookies.

Better Auth authenticates the human and establishes the session. Conclave
resolves that authenticated identity to its own `User` record and remains the
sole owner of authorization for Conclave resources and actions.

Conclave owns and enforces:

- `Workspace` records and Workspace membership/roles;
- Project access;
- Host visibility, management, pairing, and Workspace bindings;
- Worker installation and execution permissions;
- Credential Profile ownership, sharing, use, and grants;
- Run, Task, and assignment control;
- audit, usage, budget, and tenant-isolation decisions.

Better Auth Organizations are not Conclave Workspaces. Better Auth's user,
session, account, verification, and optional organization records must not be
used as the source of truth for Conclave Workspace membership, Project access,
Host permissions, or Credential Profile grants. If Better Auth Organizations
are enabled for an integration feature, they remain an authentication-provider
concept and are explicitly non-authoritative for Conclave authorization.

Cloudflare Access may continue to protect staging, internal, or administrative
infrastructure. It may provide an edge security boundary for those surfaces,
but it is no longer an application authentication dependency and application
authorization must not depend on Access identity headers being present.

Hosts do not log in through Better Auth. An authorized human pairs a Host; the
Host then uses its Conclave machine credential for Cloud connectivity.
Credential Profiles are not Better Auth sessions and never become a substitute
for human identity or authorization.

## Required boundary

Application requests that represent a human use the Better Auth session cookie
and are mapped to a Conclave User before authorization. Internal machine,
callback, and CI paths use their explicitly scoped machine credentials and are
not treated as human sessions.

The transitional custom session, development fallback, and Access-only
application paths are migration compatibility concerns, not part of the target
architecture. They must be removed or disabled as the Better Auth migration
lands; no new product feature may add another human-authentication mechanism.

## Consequences

### Positive

- one documented human authentication engine;
- conventional provider-backed browser sessions;
- D1 remains the Cloud persistence boundary;
- Conclave retains precise Workspace and resource authorization;
- Host and AI-account identities cannot be confused with human sessions;
- staging/admin Access protection can remain without coupling product auth to it.

### Tradeoffs

- Better Auth schema and lifecycle become part of the Cloud deployment;
- provider account linking and identity mapping require explicit tests;
- the transitional session tables and fallback paths require a controlled
  migration and cleanup;
- session-cookie, CSRF, redirect, and same-origin deployment behavior must be
  verified before production rollout.

## Revisit conditions

Reconsider the provider set or session storage only if requirements demand a
new identity provider, an enterprise federation protocol, or a measured D1
limitation. Do not replace Conclave Workspace authorization with Better Auth
Organizations as a shortcut.
