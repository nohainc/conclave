# Person Grants and Access Policy: Implementation Phases

Governed by [ADR-020](../decisions/ADR-020-person-grants-and-access-policy.md).
Each phase is independently reviewable. Validation follows the AGENTS.md
3-level hierarchy; `pnpm validate:full` is not part of any phase.

| Phase | Scope | Validation |
|---|---|---|
| 0 | ADR-020 and spec pointers (docs only) | review |
| 1 | Policy model: default + per-person override, `mode`, enforcement in `resolveWorkflowExecutionBindings` | focused Cloud tests, `pnpm validate:cloud` |
| 2 | AX per-person access UI, effective-access summary, `includeShared` follows per-person policy | focused AX tests, `pnpm validate:app`, `pnpm validate:cloud` |
| 3 | Owner-scoped People list and person invitations | `pnpm validate:cloud`, `pnpm validate:app` |
| 4 | Person Grants: strict, non-transferable, no re-lending, revocation at lease checks, audit | `pnpm validate:cloud` (+ Workspace service tests only if the assignment contract changes) |
| 5 | Lender usage-only reporting and privacy boundary tests | `pnpm validate:cloud`, `pnpm validate:app` |
| 6 | Per-grant quotas, Work Root selection for `work` mode | `pnpm validate:cloud` |
| 7 | One-step assign Workspace to private Space; docs | `pnpm validate:app` |

Order: 0 → 1 → (2, 3) → 4 → (5, 6) → 7. Phases 1 and 4 are security-critical and
need independent review.

## Status

- Phase 0: written.
- Phase 1: code and tests written; not yet executed (no Node toolchain in the authoring environment).
- Phase 2: partly written. Done: `mode` in the AX model, a mode selector (default Chat only) in the
  Workspace default policy, and client calls for per-person overrides
  (`AxWorkspacePersonAccessDataSource`). Remaining: the per-person list with Default/Custom status,
  "Reset to default" and the effective-access summary, which need the people list from Phase 3.

## Revised plan after the Phase 3 decision (Workspace invitations)

Decision (2026-10-17): lending uses Workspace invitations that create a Person
Grant and no people relationship (see ADR-020). Phase 3 is replaced and the
later phases are renumbered.

| Phase | Scope | Validation |
|---|---|---|
| 2b | Per-person screen on existing People: Default/Custom, edit, reset, effective-access summary | focused AX tests, `pnpm validate:app`, `pnpm validate:cloud` |
| 3 | Workspace invitation backend: table, create/list/revoke/expire, accept by signed-in invited email, single use; accept creates the Person Grant row | focused Cloud tests, `pnpm validate:cloud` |
| 3b | Workspace invitation UI: invite by email, pending list, revoke; borrower accept screen | focused AX tests, `pnpm validate:app` |
| 4 | Person Grant enforcement: borrower's own Spaces use the lender's Workspace within the effective policy; strict and non-transferable; no re-lending; revocation at lease checks; audit | `pnpm validate:cloud` |
| 5 | "People with access" list and usage-only reporting; privacy-shape tests | `pnpm validate:cloud`, `pnpm validate:app` |
| 6 | Quotas and Work Root selection for `work` mode | `pnpm validate:cloud` |
| 7 | One-step assign Workspace to private Space; docs | `pnpm validate:app` |

Order: 2b and 3 in parallel → 3b → 4 → (5, 6) → 7. Phases 3 and 4 are
security-critical and need independent review. Open design items for Phase 3:
invitation expiry length, whether the invitee needs an existing account,
and rate limits on invitations per owner.

## Status update

- Phase 1: Cloud tests green (user-reported run); the one failing test was a
  stale SQL mock in `workflow-execution-configuration.test.ts`, now updated.
- Phase 3 backend: written, not yet run. Migration `0075` (`workspace_invitations`,
  `workspace_person_grants`); `src/routes/workspace-invitations.ts`; routes
  `GET|POST /api/workspaces/:id/invitations`, `POST .../:invitationId/revoke`,
  `GET /api/workspace-invitations`, `POST /api/workspace-invitations/:id/accept`.
  Choices: 7-day expiry, max 20 pending per Workspace, invitee needs no account
  before invitation, accept requires the signed-in email to match. With no
  default policy a new borrower gets an override of chat-only with no Workers.
- Phase 2 (AX) and Phase 3b/4+ remain unverified or unstarted.

## Phase 4 (written, not yet run)

- A Space owner may select a Workspace lent to them (`loadBorrowedWorkspaces` in
  `workflow-workspace.ts`). The user-level default still allows only owned
  Workspaces.
- The Space grant on a lent Workspace is created by the lender, with permissions
  capped by the borrower's mode (chat: read; work: read and write; otherwise
  read, write and shell) and concurrency 1. The borrower never changes the
  lender's Worker scheduling. The permission cap is set when the grant is made;
  the mode check at request admission remains the live authority.
- Strict rule, enforced in `resolveWorkflowExecutionBindings`: on a lent
  Workspace every requester except its owner needs their own active Person
  Grant, so friends invited to the borrower's Space are refused (403).
- `POST /api/workspaces/:id/person-grants/:userId/revoke` (owner only) ends the
  grant, revokes the borrower's Space grants on that Workspace so the scheduler
  stops dispatching, and writes `workspace_audit_log`. Creation is audited too.
- Known limit: a step already running when the grant is revoked finishes; new
  and queued dispatches stop. Cancelling running steps is not implemented.
- No re-lending: only a Workspace owner can invite, and Space grants on lent
  Workspaces can only be created for the borrower's own Spaces.

## Phase 5 (written, not yet run)

`GET /api/workspaces/:id/people-with-access` (owner only, `workspace-people-with-access.ts`)
lists everyone with a Person Grant: name, email, status, grant date, whether they have a
custom policy, their effective mode, and usage (request count, approximate run seconds,
Worker ids, last used). Usage is read only from `worker_assignments` columns; no Space
name, Thread title, prompt or result is selected. A test asserts the exact response shape
and that seeded secrets do not appear. AX list UI is part of Phase 3b/AX work.

## Phase 6 (written, not yet run; reduced scope)

- Done: per-grant concurrent request limit (`max_concurrent_requests`, default 1,
  range 1-10; migration `0076`), set by the owner with
  `PUT /api/workspaces/:id/person-grants/:userId/quota`, enforced at request
  admission by counting the person's queued, running or waiting Work Requests on
  that Workspace (429 when at the limit). Shown in "People with access".
- Not done: total run-time limit (no reliable run-time field yet; usage is
  approximate) and per-grant Work Root. The Work Root exists only in the local
  Workspace Service, so a per-grant root needs an assignment-contract and
  service change and a separate decision. Until then `work` mode runs in the
  Workspace's own Work Root, and the owner opts into it per person.

## Phase 7 and AX status

- Phase 7 needs no new Cloud behavior: a Space owner already assigns a Workspace
  with the existing workflow-workspace selection, which now includes lent
  Workspaces. The remaining work is UI: a one-step control, and the screens
  2b (per-person overrides), 3b (invite by email, pending list, accept) and the
  "People with access" list with revoke and quota. These need Flutter
  verification (`pnpm validate:app`), which has not been run on the Phase 2 code.
- The API contract is documented in `USER_WORKFLOW_CONFIGURATION_V1.md`.

## AX sharing screens (written, not yet run)

- Data: `AxWorkspaceSharingDataSource` (people with access, invitations, revoke,
  quota, my invitations, accept) in `ax_workspace_member_access.dart`, with the
  HTTP client in `catalog_api.dart`.
- UI: `WorkspaceSharingSection` (invite by email, pending invitations, people with
  usage, concurrent-request dropdown, confirmed revoke) on each Workspace tab, and
  `WorkspaceInvitationsBanner` at the top of the Workspaces page for the invited
  person. Test: `apps/app/test/workspace_sharing_test.dart`.
- Phase 7: a Space owner picks a lent Workspace in the existing Space
  workflow-Workspace selector, since the API now returns lent Workspaces.
- Still not built: per-person editing of Workers/models/mode in AX (the API
  `member-access/people/:userId` and `AxWorkspacePersonAccessDataSource` exist),
  total run-time quota, and a per-grant Work Root.

## Per-person editor and run-time quota (written, not yet run)

- AX: "Edit access" on each person opens `WorkspaceMemberAccessSection` in person
  mode (`personSource` + `userId`): Workers, models, efforts and mode, saved as the
  person's override, with "Reset to default". A person with no policy starts at
  chat only with nothing shared.
- Cloud: `max_run_seconds_per_month` on `workspace_person_grants` (migration
  `0077`, NULL = no limit), set with
  `PUT /api/workspaces/:id/person-grants/:userId/quota {maxRunSecondsPerMonth}`
  (60 s to 31 days, or null). Enforced at admission (429) against the person's
  approximate run seconds in the current UTC month, the same figure shown in
  "People with access" (`usage.monthSeconds`). It is approximate: running
  assignments count their time so far, and a request already running is not
  interrupted when the limit is passed.
- AX shows "Run time per month" (No limit, 1-100 h) and used-of-limit.
