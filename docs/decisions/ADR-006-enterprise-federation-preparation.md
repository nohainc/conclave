# ADR-006: Enterprise federation preparation

**Status:** Accepted — deferred implementation
**Date:** 2026-09-23

## Context

Conclave may later need Workspace-level enterprise identity federation. The
current human authentication boundary already separates Better Auth identity
from Conclave authorization, so enterprise federation must not introduce a
second human-authentication stack or change the execution domain model.

## Decision

Prepare for OIDC, OAuth2, and SAML through Better Auth's SSO support when an
enterprise requirement exists. Do not install or enable the SSO plugin in the
pre-production baseline and do not add provider-specific fields to Projects,
Chats, Runs, Tasks, Workers, Hosts, or Credential Profiles now.

An enterprise identity resolves through the same application boundary as every
other human identity:

```text
Enterprise IdP -> Better Auth -> AuthenticatedIdentity
               -> Conclave User -> Workspace membership/roles
```

Better Auth Organizations are not Conclave Workspaces. Any Better Auth
organization, connection, domain, or IdP configuration is integration
metadata only. Conclave owns Workspace membership, Project access, Host
permissions, Credential Profile grants, budgets, and audit decisions.

When implemented, an individual Workspace may require a configured corporate
identity provider. That policy must be checked during human sign-in or
step-up, while the resulting authorization still uses ordinary Conclave User
and Workspace records. Existing identity consumers must continue to depend on
`AuthenticatedIdentity`/`WorkspaceSecurityContext`, never on Better Auth
provider or organization APIs.

## Consequences

- GitHub, Google, passkey, OIDC, OAuth2, and SAML can share one identity
  boundary.
- A User can belong to Personal, Company, and Client Workspaces regardless of
  which provider authenticated the session.
- Enterprise federation can be introduced without changing orchestration or
  persistence schemas.
- Provider configuration, domain verification, account linking, and JIT/SCIM
  provisioning remain future design work.
