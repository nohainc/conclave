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
