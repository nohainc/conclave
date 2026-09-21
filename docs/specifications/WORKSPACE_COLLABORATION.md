# Workspace Collaboration and Invitations

**Status:** Normative Architecture v2 specification

## Membership lifecycle

Workspace invitations are scoped to one Workspace and may optionally be scoped
to one Project. They contain a hashed one-time token, invited email, role,
inviting actor, expiration, and acceptance metadata.

The lifecycle is:

```text
pending -> accepted
pending -> expired
pending -> revoked
```

Accepting an invitation requires an authenticated User whose email matches the
invitation. A project-scoped invitation grants only the named Project as a
collaborator. It does not grant access to unrelated Projects in the Workspace.

Owners and Administrators may change non-owner roles, suspend members, or
remove members. The owner cannot be removed, suspended, or demoted through the
member API.

## Tenant isolation

Every read and mutation resolves through the authenticated User's Workspace
membership and then the Project membership. A member can share a Project,
Chat, and Run only when explicitly granted that Project. Cross-Workspace
references return not-found or forbidden responses without revealing resource
existence.

## Attribution

Invitation creation/acceptance/expiry, role changes, membership activation,
suspension/removal, and Run control actions append an `audit_log` record with:

- Workspace;
- actor type and authenticated User ID;
- action;
- target type and ID;
- structured details;
- timestamp.

Audit records are append-only evidence of who performed a control action; they
are not used as a substitute for authorization.
