# Authentication, Multi-User, and Tenancy

**Status:** Proposed architecture  
**Scope:** Conclave AX Cloud, Studio, Agents, Projects, API

## 1. Principle

Conclave AX is a multi-user cloud service. Authentication and authorization belong to Conclave AX Cloud.

Studio is a client. Conclave Agents are machine identities. AI Workers/Plugins are execution identities and are never treated as human users.

The tenancy hierarchy is:

```text
User
  -> Workspace
      -> Project
          -> Chat
              -> Goal
                  -> Run
```

A Workspace is the security, membership, and billing boundary.

## 2. Workspace

A Workspace may be:
- personal — initially contains one User;
- team — contains multiple Users.

The same underlying domain type is used for both. A personal Workspace can later add members without data migration.

Workspace owns:
- members and roles;
- Projects;
- registered Conclave Agents;
- Worker configurations;
- plugin policies;
- budgets/quotas;
- credentials stored in Cloud;
- audit history;
- billing/plan settings where applicable.

## 3. User identity

A User authenticates to Conclave AX Cloud and may belong to multiple Workspaces.

Initial Workspace roles:

- `owner` — membership, billing, security, deletion, all settings;
- `admin` — manage Projects, Agents, Workers, plugins, and members except ownership/billing-sensitive actions;
- `member` — create/use Projects, Chats, Goals, and allowed Workers;
- `viewer` — read-only access where enabled.

Do not create an elaborate enterprise permission language for v1. Project-level access can be added as a small allowlist/role override where required.

## 4. Project access

A Project belongs to exactly one Workspace.

A Project groups:
- Chats;
- repository/resource context;
- default execution/quality policy;
- allowed Agents/Workers;
- project-specific plugin configuration;
- project-specific budgets;
- artifacts and run history.

Workspace roles apply by default. Optional Project membership restricts sensitive Projects to selected Workspace users.

Every read/write query must be scoped by authenticated Workspace and Project ownership. IDs alone never authorize access.

## 5. Human sessions

Studio Web and Studio Desktop authenticate as the human User.

Use short-lived/session-based authentication suitable for browser and desktop clients. Do not compile long-lived bearer secrets into Flutter Web.

The authenticated session resolves:

```text
userId
activeWorkspaceId
authorizedProjectIds
roles
sessionId
```

Cloud APIs derive tenant scope from the authenticated identity instead of accepting arbitrary workspace ownership claims from clients.

The application-facing identity contract is provider-neutral. A future
enterprise OIDC, OAuth2, or SAML connection will produce the same
`AuthenticatedIdentity` and then use ordinary Conclave User, Workspace
membership, Project access, Host permissions, and Credential Profile grants.
Better Auth Organizations and enterprise directory groups are integration
metadata, not Conclave Workspaces or authorization claims.

Better Auth is the sole human authentication implementation. GitHub and Google
are the initial social methods, and passkeys are an additional passwordless
method. Studio Web uses same-origin, HttpOnly cookie sessions; it does not
receive or store human authentication tokens in Dart code. Passkey private keys
remain on the device or security key. Conclave stores only the public WebAuthn
credential, counter, and authenticator metadata, and users can remove an
enrolled passkey from the Account page.

Enterprise federation is deferred until a concrete company requirement exists.
When enabled, a Workspace may require its configured corporate identity
provider, but the resulting session will not alter Project, Run, Task, Worker,
Host, or Credential Profile schemas. Better Auth SSO is the planned integration
point; Conclave will not add a parallel SAML/OIDC authentication stack.

## 6. Conclave Agent identity

A Conclave Agent is not a User. It is a registered machine/service identity belonging to one Workspace.

Agent registration flow:

1. authenticated User creates/registers an Agent in Studio;
2. Cloud issues a one-time enrollment code/token;
3. installed Agent exchanges it for a durable machine credential;
4. Agent stores that credential in the host OS secure credential store;
5. Cloud records Agent id, Workspace, host metadata, public key/credential fingerprint, version, and status.

Agent credentials:
- cannot log into Studio as a human;
- are scoped to the owning Workspace;
- can only access assignments/configuration required by their permissions;
- are independently revocable;
- rotate without changing User credentials.

Host pairing is deliberately separate from this human session. An authenticated
User with `host.manage` creates a one-time, expiring enrollment. The Host
exchanges that enrollment and receives its own machine credential, which it
stores in the Host secure store. It never stores the User's Better Auth cookie,
and it never authenticates as that User. Human logout or session revocation does
not delete or invalidate an enrolled Host; Host revocation independently
invalidates its machine credential and live gateway access. Re-enrollment with
a newly authorized one-time enrollment rotates the machine credential.

## 7. Plugin and Worker identity

Plugins and Workers are execution resources, not authentication principals for normal Cloud access.

A Worker belongs to a Workspace and is hosted by a Conclave Agent.

A Worker may use:
- local subscription/session credentials;
- local API credentials;
- Cloud-managed encrypted credentials;
- an interactive web/cloud connector session.

Credential location and policy are explicit. Secrets are never included in ordinary Task, Event, Chat, Artifact metadata, or plugin manifests.

## 8. Invitations

Team Workspace flow:

```text
Owner/Admin
  -> invite email/user
  -> pending invitation
  -> user authenticates
  -> accepts
  -> Workspace membership created
```

Invitations expire and are single-use.

## 9. Audit

Security-sensitive actions create append-only audit events:

- login/session changes;
- member invite/remove/role change;
- Agent enrollment/revocation;
- plugin install/update/permission approval;
- Worker configuration changes;
- credential changes;
- Project access changes;
- Goal/run control;
- approvals/waivers.

Audit events are Workspace-scoped and attributable to User, Agent, or system actor.

## 10. Initial acceptance

Multi-user support is acceptable when tests prove:

1. User A in Workspace A cannot access Workspace B by changing IDs;
2. two Users in one Workspace can collaborate in one Project/Chat according to roles;
3. a revoked Agent can no longer receive or submit work;
4. a Workspace member cannot use Workers/credentials from another Workspace;
5. Chat/Goal/Run/Artifact queries are tenant scoped;
6. audit events identify who changed configuration or controlled a Run.
