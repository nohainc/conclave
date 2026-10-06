# Workspace Project Grants read model 1.1

Cloud owns grant authorization and persistent state. AX caches shared read models
for rendering and optimistic interactions; cached status or permissions never
authorize execution. The existing Cloud admission checks remain authoritative.

## Project collection

`GET /api/projects/:projectId/workspaces` returns `{ workspaces: [...] }` after
Project membership authorization. Each row includes the existing grant identity,
Project/Workspace IDs, display metadata, status, permission/capability policies,
concurrency, timestamps and expiration. The collection contains active and
suspended, unexpired grants; execution choices use active grants only.

AX stores the collection under `project:<id>:workspace-grants` for the authenticated
session with a one-minute stale window. Workstreams and Project settings reuse
cached data and share pending reads. Optimistic changes are independent overlays:
create inserts a local row, permission edits replace permission choices, and
revoke removes the row. Failed writes roll back their overlay; successful writes
invalidate and revalidate that Project collection. Failed reconciliation preserves
the confirmed local change and exposes retry rather than reporting the write
itself as failed. Optimistic create IDs cannot be used for edit/revoke requests.

Mutation URLs and payloads remain unchanged:

- `POST /api/projects/:projectId/workspaces` grants a Workspace access.
- `PATCH /api/workspace-project-grants/:grantId` updates grant permissions/policy.
- `DELETE /api/workspace-project-grants/:grantId` revokes a grant.

The existing `project_workspace_grant.updated` change signal revalidates the
owning collection independently of navigation. It also refreshes the Workspace
aggregate read. Project deletion and session clearing remove optimistic state
and fence late reads/writes. No complete grant collection is broadcast.

## Workspace aggregate

Version 1.1 adds `activeProjectGrantCount: number` to each row returned by the
existing `GET /api/workspaces`. It is a nonnegative integer, zero when absent
from the aggregate. One authorized D1 statement aggregates the entire result;
AX performs no per-Project grant reads to compute this field.

Counts include distinct Project IDs where the grant is active, expiration is
absent or later than the request's UTC timestamp, and the Project is not archived.
Suspended, revoked and expired grants, archived/deleted Projects and duplicate
grants to the same Project do not inflate counts. Ownership restricts the result
to the caller's non-revoked Workspaces. Project membership is not a counting
requirement: a Workspace owner may contribute to a Project without membership.
No Project details or member identities are revealed by the aggregate.

AX retains its `projectGrantCount` view-model property. Parsing prefers the new
field, accepts the legacy property when present, and defaults to zero otherwise.
Older clients may ignore the additive field. Deploy the Cloud read-model update
before AX when full counts are required. No database migration, new HTTP route,
mutation compatibility change or runtime protocol change is needed.

## Verification

`workspace-grant-summary.test.ts` executes the production list handler against
the SQLite baseline with real grant data and verifies ownership, statuses,
expiration, archived Projects, duplicates, zero counts and a one-read 30-Project
case. AX tests cover one-request response parsing, zero grant-counting reads with
30 Projects, cache isolation and optimistic mutation races. Live production
migration/deployment and browser event delivery are outside this deterministic
verification.
