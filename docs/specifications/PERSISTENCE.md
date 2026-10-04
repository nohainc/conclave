# Persistence Contracts

Cloud owns server-side persistence and accesses D1 from its route and service
modules. The v8 schema in
[0001_conclave_v8.sql](../../apps/cloud/migrations-v8/0001_conclave_v8.sql) is
the clean development baseline. Workspace owns its local registry, Profiles,
Engines, session state, logs, and Work Root in the local data directory.

## D1 schema lifecycle

`0001_conclave_v8.sql` has been applied to production and is now immutable,
even though the v8 release declaration remains withheld. Its contents must not
be edited to repair production. All schema changes use new, ordered forward
migrations (for example, `0002_<purpose>.sql`) and the normal production
migration flow. The desktop auth audience correction is recorded in
[`0002_desktop_auth_multi_audience.sql`](../../apps/cloud/migrations-v8/0002_desktop_auth_multi_audience.sql).
[`0003_workspace_installations.sql`](../../apps/cloud/migrations-v8/0003_workspace_installations.sql)
introduces stable installation ownership independently from runtime
credentials. It seeds ownership from runtime identity history and release audit
events. If legacy history reuses an installation ID across multiple Workspaces,
it preserves a single owner and selects the sole non-revoked Workspace; when
all associated Workspaces and runtime identities are revoked, it selects the
newest historical Workspace while retaining that owner. It aborts on mixed
owners, multiple non-revoked Workspaces, a live runtime on a revoked Workspace,
or one Workspace mapped to multiple installation IDs.
[`0004_workspace_runtime_identity_uniqueness.sql`](../../apps/cloud/migrations-v8/0004_workspace_runtime_identity_uniqueness.sql)
adds a unique partial index that permits at most one unrevoked runtime identity
per Workspace. It aborts if preexisting rows violate that invariant.
[`0005_workspace_schema_alignment.sql`](../../apps/cloud/migrations-v8/0005_workspace_schema_alignment.sql)
aligns the deployed `execution_workspaces` and `workspace_runtime_identities`
table definitions and indexes with the v8 canonical contract while preserving all
existing rows.

Wrangler records applied migrations by filename. Editing an applied migration
does not make it run again, so never rewrite, remove, or reorder an applied
migration. New development databases apply the complete ordered migration set.
Production migrations must preserve existing records, verify migration
invariants such as before/after row counts, and fail atomically if those checks
do not pass. Never silently discard active human sessions during a schema
change.

Project-scoped records derive authorization from Project membership. Execution
Workspaces are user-owned and connect to Projects only through explicit
Workspace Project Grants. Human and runtime bearer credentials are held in OS
secure storage; Cloud stores only their token hashes. Provider CLI sign-in is
owned by the provider CLI's local configuration. Plaintext credentials are not
stored in D1.

## Row and payload split

D1 stores identifiers, relationships, statuses, compact JSON contracts, provenance, digests, and R2 references. Artifact content that is large or unstructured is written to R2 and represented by an immutable reference containing bucket, key, size, media type, and digest. Small content may use an inline form under the same artifact contract.

## Work v1 state

Work Requests and Workflow Steps are persisted with dependencies, immutable
Workflow/execution snapshots, and assignment references. Runs and Worker
assignments record execution state. A Work Request containing any stateful
Step holds one Workstream runtime lease for its lifetime; the lease selects the
Primary Workspace, serializes stateful requests for that Workstream, and
provides a fencing token checked before filesystem mutation. Workspace resolves
the Workstream directory from immutable Project and Workstream IDs. Research
and Plan remain stateless, read-only Steps and may run on another eligible
granted Workspace; they do not mutate that directory. D1 persists Work and
lease metadata, not the local Workstream directory or its Git state. Persisted
v8 records are authoritative current state; durable realtime events notify AX
of changes and let it refresh that state. The schema does not include the
retired pre-v8 Goal/Phase/Attempt/ModelCall/Finding/Verification aggregate.

Workspace Project Grants authorize a Project to use an owner-controlled
Workspace. A grant does not register repositories or map Project
repository/path identifiers to local paths. Provider CLIs manage Git inside
the ID-derived Workstream directory through the generic CLI Worker Engine;
Workspace exposes only read-only Git observability for repositories found
there.

Workstream authorization is evaluated from current Project membership and the
Workstream access policy. The database does not duplicate Project roles in a
separate Workstream membership table.

Every Workspace runtime identity has a credential hash. Stable installation
ownership lives in `workspace_installations`, which records the owner,
canonical Workspace, and active/released state. Its primary key permits one
ownership row per installation, and a unique partial index permits a Workspace
to have only one active installation binding. Runtime identity rows can be
rotated or revoked independently; a unique partial index permits one unrevoked
runtime identity per Workspace. Explicit release revokes runtime identities,
clears their legacy installation ID values, and marks the ownership row
released so another account can register the installation. The legacy runtime
`installation_id` column remains for schema compatibility but does not decide
ownership.

If a known pre-v8 registration has its runtime identity but lacks the v8
`workspace_installations` row, Workspace may request explicit reconciliation
after a fresh browser-approved desktop sign-in. Cloud verifies the exact local
Workspace/runtime IDs, current Workspace owner, persistent installation ID,
absence of competing active bindings, and absence of a recorded Release. Cloud
then inserts the canonical ownership row and an audit event atomically. Email
matching is never used. Ambiguous or foreign-owner state fails closed; an
active foreign owner must Release the installation first.

`worker_assignments.worker_type_id` identifies the logical Worker type;
`workspace_worker_id` identifies the Workspace's local Worker slot. The clean
v8 baseline stores the Cloud Workflow instance ID on
`runs.workflow_instance_id` and limits Workstream execution policy to logical
Worker type IDs. It has no external-execution side table or provider allowlist.
Apply this baseline only to a fresh development database; it is not an upgrade
migration for an existing database.

## Durable realtime event retention

Durable realtime events are change notifications, not the authoritative
business record. Cloud retains event rows and their idempotency keys for 90
days. The browser must refresh current Project, Workstream, and Work state from
the authenticated read APIs after a reconnect or sequence gap; the realtime
transport does not promise historical event replay. Ephemeral events are never
persisted.

Cloud runs retention cleanup hourly and deletes up to 10,000 expired rows per
run, oldest first. Cleanup can take multiple runs to catch up after an outage
or a large backlog. Per-Workspace sequence cursors are retained indefinitely
and are never reset when old events are deleted, so sequence numbers remain
monotonic. Idempotency is guaranteed for the 90-day event retention window; a
retry after expiration may create a new event.

Human Product, Workspace Runtime, and Local Worker Protocol contracts have separate owners, endpoints, authentication, versions, and wire schemas. Keep one canonical schema source per boundary and generate language bindings from it. Shared domain IDs do not justify sharing transport envelopes.

The Work Request, Step, and lease behavior here must match the
[Work v1 Contract](WORK_V1_CONTRACT.md) and
[Architecture v8](../architecture/ARCHITECTURE_V8.md). Local directory identity
and mutation fencing are specified in
[ADR-011](../decisions/ADR-011-workstream-working-directories.md).

See [Protocol Boundaries](../architecture/PROTOCOL_BOUNDARIES.md).
