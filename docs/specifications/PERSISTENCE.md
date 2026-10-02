# Persistence Contracts

Cloud owns server-side persistence and accesses D1 from its route and service
modules. The v8 schema in
[0001_conclave_v8.sql](../../apps/cloud/migrations-v8/0001_conclave_v8.sql) is
the clean development baseline. Workspace owns its local registry, Profiles,
Engines, session state, logs, and Work Root in the local data directory.

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
retired Goal/Phase/Attempt/ModelCall/Finding/Verification aggregate.

Workspace Project Grants authorize a Project to use an owner-controlled
Workspace. A grant does not register repositories or map Project
repository/path identifiers to local paths. Provider CLIs manage Git inside
the ID-derived Workstream directory through the generic CLI Worker Engine;
Workspace exposes only read-only Git observability for repositories found
there.

Workstream authorization is evaluated from current Project membership and the
Workstream access policy. The database does not duplicate Project roles in a
separate Workstream membership table.

Every Workspace runtime identity has a credential hash. Its stable installation
ID remains bound while the identity is active. Explicit release revokes the
identity and clears that binding so the installation can be enrolled again;
this released state is not an installation-recovery path.

`worker_assignments.worker_type_id` identifies the logical Worker type;
`workspace_worker_id` identifies the Workspace's local Worker slot. The clean
v8 baseline stores the Cloud Workflow instance ID on
`runs.workflow_instance_id` and limits Workstream execution policy to logical
Worker type IDs. It has no external-execution side table or provider allowlist.
Apply this baseline only to a fresh development database; it is not an upgrade
migration for an existing database.

Human Product, Workspace Runtime, and Local Worker Protocol contracts have separate owners, endpoints, authentication, versions, and wire schemas. Keep one canonical schema source per boundary and generate language bindings from it. Shared domain IDs do not justify sharing transport envelopes.

The Work Request, Step, and lease behavior here must match the
[Work v1 Contract](WORK_V1_CONTRACT.md) and
[Architecture v8](../architecture/ARCHITECTURE_V8.md). Local directory identity
and mutation fencing are specified in
[ADR-011](../decisions/ADR-011-workstream-working-directories.md).

See [Protocol Boundaries](../architecture/PROTOCOL_BOUNDARIES.md).
