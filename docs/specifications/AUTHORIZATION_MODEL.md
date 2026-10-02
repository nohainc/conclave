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

## Tool Profile administration

Profile administration and release management use the dedicated `profiles:admin` and `profiles:release:manage` permissions. Cloud resolves authorized administrators from its configured operator identity set. Profile payloads remain signed, immutable, schema-validated releases; authorization does not replace signature verification.

## Step-up authentication and audit

Sensitive ownership or release operations may require a recent step-up proof tied to the current human session. Each route declares its required assurance and Cloud checks it before mutation. Security-relevant authorization, ownership, Workspace, Workstream, and Profile changes are written to the applicable audit stream without credentials or secret payloads.

## Secret boundary

Provider credentials stay in the local provider CLI configuration. Runtime credentials are stored in the operating system secure store. Cloud persistence, assignment messages, diagnostics, audit records, and artifacts must not contain plaintext secrets.
