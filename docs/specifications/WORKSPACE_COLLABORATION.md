# Workspace Collaboration and Invitations

This is the current workspace collaboration and invitation specification for
Architecture v4.

Conclave AX exposes these controls in Workspace Settings rather than requiring
direct API use. The Settings page provides General, Members, Invitations,
Permissions, and Audit views. Cloud remains authoritative for every read and
mutation.

The application uses these Cloud routes for the management surface:

- `GET/PATCH /api/workspaces/:workspaceId` for Workspace details and naming;
- `GET /api/workspaces/:workspaceId/members` for the member directory;
- `GET/POST /api/workspaces/:workspaceId/invitations` for invitations;
- `PATCH /api/workspaces/:workspaceId/members/:userId/role` for role changes;
- `POST /api/workspaces/:workspaceId/members/:userId/{suspend|activate|remove}`
  for membership status;
- `GET /api/workspaces/:workspaceId/audit-export` for authorized audit readers.

Invitation and audit views may be unavailable to ordinary members. This is a
permission result, not a client-side hiding convention; member and resource
access is still evaluated by Cloud on every request.

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
