# Authorization Model

**Status:** Current security policy for Conclave AX, Cloud, Workspace ownership, Threads, and Tool Profiles.

Cloud resolves the authenticated Better Auth session to an active Conclave user. It derives Space roles from `space_memberships`; it does not trust client-supplied organization or Workspace membership claims.

## Space access

Space roles are `owner`, `collaborator`, and `viewer`. Their permission sets are defined in `packages/security/src/index.ts`:

- Owners can read, write, and manage their Space, start Work, and control Runs.
- Collaborators default to reading, Chat, Work, and management of their own Threads. Owners can refine these rights individually.
- Viewers can read Space content.

Cloud checks membership at the resource boundary. A missing, suspended, or deactivated user is denied.

## Workspace execution access

A Workspace has one Cloud owner. The owner manages the Workspace runtime. Space access to a Workspace is granted explicitly through a Space-to-Workspace Grant. Grants scope which Workspace resources a Space's Threads may use; they do not change Workspace ownership.

Cloud authorizes each Thread operation and assignment using Space membership, Workspace ownership/grants, Thread state, logical Worker readiness, and scheduling policy. Workspace independently enforces local permissions, readiness, concurrency, deadlines, cancellation, and process cleanup.

Assignment execution uses one canonical permission vocabulary across Cloud,
Workspace Runtime Protocol, Workspace, and Engine admission:

- `repository:read`
- `repository:write`
- `shell:execute`
- `network:use`

Cloud intersects only the permissions allowed by the requester's Space member rights
with `workspace_space_grants.allowed_permissions_json`, then applies the
request's read-only Step policy. Cloud does not pretend to know the local
Worker permission set. Workspace compares the exact permission IDs in the
assignment snapshot against the installed Worker's local permission ceiling;
unknown names are rejected. Space access policy values such as `view`,
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

Sensitive ownership or release operations may require a recent step-up proof tied to the current human session. Each route declares its required assurance and Cloud checks it before mutation. Security-relevant authorization, ownership, Workspace, Thread, and Profile changes are written to the applicable audit stream without credentials or secret payloads.

Workspace ownership reconciliation is a narrow migration recovery operation.
It requires a desktop session created by fresh browser approval and an exact
local Workspace/runtime identity that Cloud can prove belongs to the signed-in
user. Cloud may reconstruct a missing v8 installation binding only when there
is no competing active binding and no recorded Release. It never transfers an
active foreign-owned installation or uses email equality as ownership proof.
The reconciliation is audited; ambiguous state requires operator investigation.

## Secret boundary

Provider credentials stay in the local provider CLI configuration. Runtime credentials are stored in the operating system secure store. Cloud persistence, assignment messages, diagnostics, audit records, and artifacts must not contain plaintext secrets.

## Space member rights v1

Space membership remains the boundary for reading. Owners retain all member
rights and control Space settings and every Thread. For other members, the
owner can set five explicit booleans: `chat`, `work`, `manageOwnThreads`,
`attachWorkspace`, and `inviteMembers`. The Members tab shows these in a
checkbox grid; only the owner can edit it, and the Owner badge appears beside
the owner's name. Thread lists show the creator's email below the title when
that person is not the Space owner. The current Thread creation identity is
its immutable creation-time `lead_user_id`; the API does not reassign this field.

The v1 rights map lives at `spaces.settings_json.memberPermissions[userId]`.
Missing maps preserve role defaults: collaborators have Chat, Work and own
Thread management; viewers can read; owners have all rights. Workspace
attachment and member invitations require explicit grants for non-owners.
Malformed stored overrides fail closed. Removing a member removes their override
and revokes their contributed Workspace Grants.

`PATCH /api/spaces/:id/members/:userId/permissions` accepts
`{ permissions: { chat, work, manageOwnThreads, attachWorkspace, inviteMembers } }`.
All five fields must be booleans; extra fields are rejected. Owner rights cannot
be changed. Existing role presets remain available through the role endpoint
and reset the member's explicit rights to that preset. Space and member read
models include effective `permissions`. Ordinary Space responses omit the internal member and invitation permission maps. General Space settings writes cannot
change the member or invitation permission maps.

Workflow enablement is configured on global/Space Workflows, together with its
selected Workspace. Only the Space owner may change Space workflow settings.
Submission and validation enforce the effective workflow enabled flag and the
requester's member rights. Dispatch continues to check current member rights,
Workspace grants, and accepted execution snapshots. Chat requires Chat permission.
Migration 0022 converts existing Space-wide Work denials to per-workflow disabled
flags and removes `settings.allowWork`; obsolete writes receive 400. History is
preserved, and accepted runs retain their execution evidence. Already-running
provider calls are not cancelled by a settings change.

Own Thread management permits creation and management of Threads created by
that member, while the owner can manage every Thread. It does not grant rights
to execute Chat or Work. Composer choices configure the next turn and do not
change historical execution metadata.

A member with `attachWorkspace` can attach only a Workspace they own and must
explicitly authorize the contribution. Workspace ownership is checked
independently of Space rights. The Space owner or Workspace owner may revoke
the attachment; only the Workspace owner manages the Workspace itself.
The Space UI replaces the technical grant-permission editor with the Work
switch. New UI attachments allow repository reads/writes and shell execution,
subject to the Workspace's local Worker permission ceiling. Existing grant
restrictions and network policy still apply. Work rights provide the execution
ceiling, intersected with the grant and the request's read-only Step policy.

Members with `inviteMembers` may invite people with a subset of their own
rights, including read-only invitations. `POST /api/spaces/:id/invitations`
accepts the same optional `permissions` object. Invitation rights are
snapshotted in `settings.invitationPermissions[invitationId]` and intersected
with the inviter's current rights at acceptance. Revoked invitation authority
prevents acceptance. Delegated inviters see and revoke only their own pending
invitations. Invitation acceptance cannot rewrite an existing member's rights.

These are additive API/settings changes; no D1 migration or runtime protocol
change is needed. Deploy Cloud before the updated AX app. Older clients retain
role defaults, but their technical controls cannot bypass current member rights.

## People

An accepted Space membership automatically establishes symmetric user-ID relationships with co-members. Pending invitations never grant People visibility. Authenticated `GET /api/people` exposes only established peers and supports no global search or caller-supplied owner. Known-Person invitations require both a caller-owned relationship and Space invitation rights; removal from a Space preserves the relationship but removes that Space authorization. See [People v1](PEOPLE_V1.md).

Known-Person Space invitations persist `invitee_user_id`; recipient inbox access and Accept/Reject compare the authenticated user ID, independent of email changes. Email-addressed invitations remain available for new collaborators and bind identity on acceptance. Invitation selection grants no membership or consent. Both People and Space entry points use the same permission-checked invitation endpoint. Migration 0024 adds a unique pending Space/recipient identity constraint without changing accepted memberships.
