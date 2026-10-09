# Workspace Space Grants read model 1.1

Cloud owns grant authorization and persistent state. AX caches shared read models
for rendering and optimistic interactions; cached status or permissions never
authorize execution. The existing Cloud admission checks remain authoritative.

## Space collection

`GET /api/spaces/:spaceId/workflow-workspace/grants` returns `{ workspaces: [...] }` after
Space membership authorization. Each row includes the existing grant identity,
Space/Workspace IDs, display metadata, status, permission/capability policies,
concurrency, timestamps and expiration. The collection contains active and
suspended, unexpired grants; execution choices use active grants only.

AX stores the collection under `space:<id>:workspace-grants` for the authenticated
session with a one-minute stale window. Threads and Space settings reuse
cached data and share pending reads. Optimistic changes are independent overlays:
create inserts a local row, permission edits replace permission choices, and
revoke removes the row. Failed writes roll back their overlay; successful writes
invalidate and revalidate that Space collection. Failed reconciliation preserves
the confirmed local change and exposes retry rather than reporting the write
itself as failed. Optimistic create IDs cannot be used for edit/revoke requests.

Canonical grant mutation URLs:

- `POST /api/workspaces/:workspaceId/spaces/:spaceId/grant` grants a Workspace access.
- `PATCH /api/workspace-space-grants/:grantId` updates grant permissions/policy.
- `DELETE /api/workspace-space-grants/:grantId` revokes a grant.

The existing `space_workspace_grant.updated` change signal revalidates the
owning collection independently of navigation. It also refreshes the Workspace
aggregate read. Space deletion and session clearing remove optimistic state
and fence late reads/writes. No complete grant collection is broadcast.

## Workspace aggregate

Version 1.1 adds `activeSpaceGrantCount: number` to each row returned by the
existing `GET /api/workspaces`. It is a nonnegative integer, zero when absent
from the aggregate. One authorized D1 statement aggregates the entire result;
AX performs no per-Space grant reads to compute this field.

Counts include distinct Space IDs where the grant is active, expiration is
absent or later than the request's UTC timestamp, and the Space is not archived.
Suspended, revoked and expired grants, archived/deleted Spaces and duplicate
grants to the same Space do not inflate counts. Ownership restricts the result
to the caller's non-revoked Workspaces. Space membership is not a counting
requirement: a Workspace owner may contribute to a Space without membership.
No Space details or member identities are revealed by the aggregate.

AX retains its `spaceGrantCount` view-model property. Parsing prefers the new
field, accepts the legacy property when present, and defaults to zero otherwise.
Older clients may ignore the additive field. Deploy the Cloud read-model update
before AX when full counts are required. No database migration, new HTTP route,
mutation compatibility change or runtime protocol change is needed.

## Verification

`workspace-grant-summary.test.ts` executes the production list handler against
the SQLite baseline with real grant data and verifies ownership, statuses,
expiration, archived Spaces, duplicates, zero counts and a one-read 30-Space
case. AX tests cover one-request response parsing, zero grant-counting reads with
30 Spaces, cache isolation and optimistic mutation races. Live production
migration/deployment and browser event delivery are outside this deterministic
verification.

## Space UI member rights (v1)

Workspace selection and workflow enablement live on the Space Workflows tab.
Selecting the owner's Workspace authorizes missing execution grants; global
selection also covers inherited and new owned Spaces. Existing grant policies,
suspension, expiration, and member rights remain authoritative. Only Workers
from the selected Workspace may be resolved for new execution. The Space
Workspaces tab and its connection API are removed in migration 0022.

Canonical grant APIs retain contribution confirmation and `attachWorkspace`
checks for members contributing their own Workspace. Space owners can revoke
attachments without acquiring Workspace ownership. Read metadata still exposes
`canOpenWorkspace` and `canRevoke`, derived from current ownership/membership.
See [Workflow Workspace selection](USER_WORKFLOW_CONFIGURATION_V1.md#workspace-selection)
and [Space member rights](AUTHORIZATION_MODEL.md#space-member-rights-v1).
