# Space and Thread terminology — completion audit

## Scope

The product hierarchy is now Space → Thread → Conversation. This is a domain
rename across the existing v8 execution path, not a new execution architecture.
Spaces replace Projects; Threads replace Workstreams. Logical Workers, signed
Tool Profiles, Workspace ownership and Conclave-owned canonical history retain
their responsibilities.

## Phase audit

| Phase | State found at handoff | Completion |
| --- | --- | --- |
| 1 — Protocol and Core | New Space/Thread types existed; remaining router test and execution-permission references used old names | Canonical schema, generated TypeScript/Dart bindings, Core exports and tests use Space/Thread identities |
| 2 — Cloud persistence and API | Routes and much of the baseline had been renamed; smoke/schema references were incomplete | Space/Thread routes, SQL baseline, seed data, coordination, scheduling, grants and acceptance fixtures agree |
| 3 — Workspace runtime | Thread filesystem files were renamed but verification was unfinished | Local lifecycle, markers, policies, assignment handling and tests use Space/Thread contracts |
| 4 — AX app | Models and views were partly renamed | Routes, stores, cache keys, UI copy, invitations, permissions, sidebar grouping and tests use Space/Thread concepts |
| 5 — Site, Profile Lab, docs and scripts | Public site and most docs/scripts retained old product terminology | Components, copy, current contracts, ADR links, schema guards and validation scripts are updated |
| 6 — Verification and commit | No complete acceptance evidence | All acceptance checks passed; the completed rename is ready for the repository commit |

The audit is based on source inspection and executable checks, not the completion
claims in the handoff text. The architecture guard rejects retired product type
names, IDs and API paths. External provider names and technical tool formats are
not renamed: `GOOGLE_CLOUD_PROJECT`, Xcode `project.pbxproj`, and the verb
`projectContextState` remain valid.

## Contract and compatibility impact

API resource paths are `/api/spaces` and `/api/threads`; product envelopes and
permission scopes use `spaceId` / `threadId`, Space roles, and corresponding
realtime streams/events. SQL uses `spaces`, `threads`, Space membership and grant
tables, and `space_id` / `thread_id`. There are no legacy resource aliases.
Clients, Workspace runtime and generated bindings must be released together.
Signed Profile templates that reference renamed product placeholders or authority
fields need a newly qualified release; existing signatures are never rewritten.

The v8 D1 schema remains a fresh-start baseline. Editing it does **not** migrate an
initialized database. Existing environments require a separately reviewed data
conversion preserving entity IDs, memberships, invitation state, history, grants
and references, or an explicitly authorized fresh provision. Back up and verify
row counts, foreign keys and attribution before switching traffic. Do not run the
new baseline on production as an implicit rename migration.

The Thread coordinator class/binding names and fresh-start Durable Object
configuration have changed. An existing deployed namespace needs an explicit,
state-preserving Cloudflare migration plan rather than replaying edited historic
migration tags. Drain active execution and retain lease/fencing evidence before
cutover. No remote database, namespace or application is changed by this task.

Workspace's ID-only directory layout remains `<WorkRoot>/<spaceId>/<threadId>`.
Stable entity IDs preserve the physical directory location during a terminology
change; this task deliberately does not introduce a `.conclave/spaces/...` tree or
move user files. That alternative in the handoff analysis is not the normative
v8 filesystem contract. Marker names/fields and local contract metadata now use
Thread/Space naming; existing installations must have their metadata converted
or be deliberately reprovisioned before activating the renamed runtime. Native
provider handles remain local and are never imported from Cloud.

Space/Thread labels, URLs and API shapes are breaking changes for older clients,
local read caches and unreleased v8 installations. Clear product read caches at
cutover and restart local clients. Production deployment is outside this task.

## Verification record

The repository acceptance command is `pnpm check`, including the canonical
schema/binding checks, architecture guards, formatting, lint, all TypeScript tests
and `scripts/check-dart-packages.sh`. The latter resolves package dependencies,
builds the bundled CLI Engine, and analyzes/tests protocol, runtime, Profile,
Engine, design, Workspace, Profile Lab and AX packages. The site is additionally
checked, tested and built using its own toolchain. Fixture provider acceptance
proves the protocol path; it does not substitute for a live-provider release gate.

Final verification (2026-10-08): `pnpm check` passed, including 701 main
TypeScript/script tests, all nine Dart/Flutter package checks and the 16-test
clean-room fixture gate. Workspace passed 332 tests with 10 opt-in live-provider
checks skipped; AX passed 589 tests and Profile Lab passed 144. Site checking
reported zero errors/warnings; its four tests, nine-page build, and content,
security, analytics privacy, release, accessibility, responsive and performance
checks passed. `git diff --check` passed. Live provider behavior and migration of
an already initialized remote environment remain separate release checks; no
remote deployment was performed.

## Follow-up review — 2026-10-08

The review's duplicated fallback examples were confirmed and removed. The audit
also removed repeated comparison/pattern alternatives from navigation, realtime
notifications, cache retention and persisted read-cache encoding. Current API
clients use only `spaces` / `space` and `threads` / `thread` envelopes. API and
navigation regression tests cover the renamed paths, response identities and
rejection of obsolete product paths/envelopes. The architecture guard additionally
rejects redundant operands without mistaking `page.cursor ?? cursor` or
`spaceId ?? this.spaceId` for duplicate expressions. Provider-native and Xcode
names remain valid; no old product endpoint aliases were introduced.

The GitHub CI run for `ca6464b199` completed successfully, including all eight
validation jobs, both native macOS builds and the final acceptance gate:
[CI evidence](https://github.com/nohainc/conclave/actions/runs/37763559782).
This is executable evidence for the rename and CI commits, not evidence that
production has adopted their database contract.

Read-only inspection of the configured `conclave-v8-production` database found
71 schema tables, including `projects`, `workstreams` and older runtime
entities. The required `spaces`, `threads`, `space_memberships`,
`space_invitations` and `workspace_space_grants` tables were absent. Applied
migration names extend through `0016_workflow_step_runs.sql`, confirming why
replaying edited migration files would not perform the cutover. Its foreign-key
check returned zero violations in the existing schema; that does not establish
compatibility with the current runtime. A copied snapshot of the existing local
D1 store likewise had 55 schema tables with old product names and zero
foreign-key violations. No user rows were modified, no databases were reset,
and no database or application was deployed during this review.

`scripts/space-thread-schema-preflight.mjs` now checks the inspected schema before
production migration preparation/application. It rejects missing renamed tables/identity columns,
retired tables/columns, mixed states and failed inspection responses. The observed
production schema is rejected. This is a deployment prerequisite check, not a
conversion migration and not a replacement for reviewing pending schema changes.

### Required cutover before activating the renamed runtime

1. Suspend writes/executions and capture a restorable D1 backup and local metadata
   backup. Record entity IDs, row counts, memberships/invitations, history sequence
   bounds, execution/session ownership and foreign-key consistency.
2. Inventory the actual deployed schema, persisted JSON scope/event identifiers,
   signed Profile placeholders, Worker versions and Durable Object migration
   history. This environment contains older runtime entities as well as old
   terminology; a five-table rename alone is insufficient.
3. Rehearse an explicit data-preserving conversion against a copy of that exact
   schema. Preserve collaboration/history/attribution and stable directory IDs;
   reconcile older runtime entities according to the current v8 contract. Do not
   add legacy API aliases or rewrite already-signed Profile releases.
4. Compare counts, IDs, history revisions and foreign keys against the backup.
   Validate grants and invitation access and execute Chat/Work and session-resume
   acceptance against the converted copy. Verify the coordinator namespace's
   state-preserving migration independently.
5. Apply the reviewed conversion during a coordinated Cloud/client/Workspace
   cutover; clear obsolete read caches, convert local markers and restart clients.
   Run the schema preflight and post-cutover access/execution checks before
   reopening writes. Keep the backup and rollback plan until verification passes.

A production conversion is still required and has not been applied. A disposable
environment reset is a separate, explicit choice; this review does not authorize
or perform one. The renamed implementation must not be described as production
migration complete until this cutover has executable evidence.

Follow-up verification: the full composed `pnpm check` passed locally (699 main
TypeScript/script tests, 16 explicit Cloud fixture tests, all Dart/Flutter suites,
332 Workspace tests, 144 Profile Lab tests and 591 AX tests). Ten opt-in live
provider tests were skipped. Additional schema-preflight/hygiene regression tests
pass; the production inspection fails the cutover preflight as intended.

## Operational cutover tooling

The production migration command now has a separately confirmed, one-off
cutover path for an existing pre-rename database. It instantiates an isolated
`0017_space_thread_cutover.sql` from the inspected schema instead of editing or
replaying the fresh-start baseline. It preserves historical extra tables/columns
and all row identities. Schema assertions reject drift; a transaction restores
foreign keys, constraints, indexes and triggers. Metadata conversion changes
structural Space/Thread keys and realtime scopes/events, preserving free-form
user text and leaving signed Profile payloads/signatures untouched. Ambiguous
old/new metadata key collisions stop the conversion.

The cutover requires both `CONFIRM_SPACE_THREAD_CUTOVER=YES` and a nonempty,
verified backup path in `CONCLAVE_CUTOVER_BACKUP_FILE`, in addition to the usual
`CONFIRM_PRODUCTION_MIGRATION=YES`. Without these, it stops before remote changes.
Stop writes and runtime executions for the coordinated cutover; do not equate a
private backup file's presence with a completed rehearsal.

~~~sh
CONFIRM_PRODUCTION_MIGRATION=YES \
CONFIRM_SPACE_THREAD_CUTOVER=YES \
CONCLAVE_CUTOVER_BACKUP_FILE=/private/tmp/conclave-pre-cutover-backup.sql \
bash scripts/migrate-production-d1.sh
~~~

With the user's explicit authorization, a private production backup was exported
and the exact generated cutover rehearsed locally on 2026-10-08. All 71 tables
and 1,145 rows were preserved, with zero foreign-key violations. Every current
baseline table and column exists in the converted copy. Fixture tests additionally
verify rollback on schema drift and ambiguous metadata, preservation of IDs,
invitation tokens, user text and signed Profile signatures, and mixed-schema
rejection. Static/TypeScript acceptance checks passed. The backup is outside the
repository; no user data is committed. After explicit user authorization, production application completed on
2026-10-08. `0017_space_thread_cutover.sql` applied successfully and no remaining
migrations were pending. Remote checks confirmed all 71 schema tables and the
1,145 pre-cutover rows were preserved; the migration history contains one new
record (1,146 rows including that record), with zero foreign-key violations.
The Space/Thread preflight now passes remotely. Atomic execution guards additionally
reject active Work Requests, Worker assignments and leases. No app/Worker release
or local Workspace metadata conversion was performed by this database operation.
The private backup remains outside version control for rollback.

### Workspace marker cutover

An initialized Work Root also needs its identity markers converted. A Cloud D1
cutover alone does not convert local directories. Stop Workspace, then preview
`node scripts/convert-workspace-thread-markers.mjs WORK_ROOT`; run the same
command with `--apply` after inspecting the IDs. It validates the entire inventory,
rejects symlinks/mismatched identities/existing current markers, preserves the
creation timestamp and user files, and retains each old marker as a
`.pre-thread-cutover` backup. The runtime continues to reject directories without
current identity markers; there is no legacy admission alias.

Signed Profiles containing retired capability names require a new qualified
release. A successful readiness probe does not validate Thread directory
admission. Include a real Chat and Work request after both cutovers.
