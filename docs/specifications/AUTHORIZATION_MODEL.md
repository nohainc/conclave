# Authorization Model

**Status:** Current security policy for Conclave AX, Cloud, Workspace ownership, Workstreams, and Tool Profiles.

Cloud resolves the authenticated Better Auth session to an active Conclave user. It derives Project roles from `project_memberships`; it does not trust client-supplied organization or Workspace membership claims.

## Project access

Project roles are `owner`, `collaborator`, and `viewer`. Their permission sets are defined in `packages/security/src/index.ts`:

- Owners can read, write, and manage their Project, start Work, and control Runs.
- Collaborators can read and write Project content and start Work.
- Viewers can read Project content.

Cloud checks membership at the resource boundary. A missing, suspended, or deactivated user is denied.

## Workspace execution access

A Workspace has one Cloud owner. The owner manages the Workspace runtime. Project access to a Workspace is granted explicitly through a Project-to-Workspace Grant. Grants scope which Workspace resources a Project's Workstreams may use; they do not change Workspace ownership.

Cloud authorizes each Workstream operation and assignment using Project membership, Workspace ownership/grants, Workstream state, logical Worker readiness, and scheduling policy. Workspace independently enforces local permissions, readiness, concurrency, deadlines, cancellation, and process cleanup.

Assignment execution uses one canonical permission vocabulary across Cloud,
Workspace Runtime Protocol, Workspace, and Engine admission:

- `repository:read`
- `repository:write`
- `shell:execute`
- `network:use`

Cloud intersects only the permissions allowed by the requester's Project role
with `workspace_project_grants.allowed_permissions_json`, then applies the
request's read-only Step policy. Cloud does not pretend to know the local
Worker permission set. Workspace compares the exact permission IDs in the
assignment snapshot against the installed Worker's local permission ceiling;
unknown names are rejected. Project access policy values such as `view`,
`discuss`, and `execute` are a separate vocabulary and are not assignment
execution permissions.

Workspace Grant writes validate permission IDs against that four-value set and
reject duplicates. Worker capability values must be current Work v1 or Worker
input capabilities. Explicit Worker IDs must be bounded IDs of Workers already
inventoried on the granted Workspace; an empty list leaves all its Workers
eligible (with at most 64 explicit IDs). An empty capability list leaves capability filtering to the
Workflow/Worker compatibility check. Network policy accepts only
`deny_all` with no hosts or `allowlist` with unique, lowercase exact DNS
hostnames (no scheme, port, path, wildcard, or IP literal). Concurrency must be
an integer from 1 through 1024 and is intersected with the Worker and Cloud
limits. The default is one concurrent assignment.

Grant status transitions are `active` ↔ `suspended`; either state may become
`revoked` or `expired`. Revoked and expired Grants are terminal. The owner API
can activate, suspend, or use the dedicated revoke operation; expiration is
driven by `expiresAt` and is not a client-settable status.

## Tool Profile administration

Profile administration and release management use the dedicated `profiles:admin` and `profiles:release:manage` permissions. Cloud resolves authorized administrators from its configured operator identity set. Profile payloads remain signed, immutable, schema-validated releases; authorization does not replace signature verification.

## Step-up authentication and audit

Sensitive ownership or release operations may require a recent step-up proof tied to the current human session. Each route declares its required assurance and Cloud checks it before mutation. Security-relevant authorization, ownership, Workspace, Workstream, and Profile changes are written to the applicable audit stream without credentials or secret payloads.

Workspace ownership reconciliation is a narrow migration recovery operation.
It requires a desktop session created by fresh browser approval and an exact
local Workspace/runtime identity that Cloud can prove belongs to the signed-in
user. Cloud may reconstruct a missing v8 installation binding only when there
is no competing active binding and no recorded Release. It never transfers an
active foreign-owned installation or uses email equality as ownership proof.
The reconciliation is audited; ambiguous state requires operator investigation.

## Secret boundary

Provider credentials stay in the local provider CLI configuration. Runtime credentials are stored in the operating system secure store. Cloud persistence, assignment messages, diagnostics, audit records, and artifacts must not contain plaintext secrets.
