# Persistence Contracts

Cloud owns server-side persistence and accesses D1 from its route and service modules. The v8 schema in [0001_conclave_v8.sql](../../apps/cloud/migrations-v8/0001_conclave_v8.sql) is the clean development baseline. Workspace owns its local registry, Profiles, Engines, session state, logs, and Work Root in the local data directory.

Project-scoped records derive authorization from Project membership. Execution Workspaces are user-owned and connect to Projects only through explicit Workspace Project Grants. Credentials and secrets are not represented in D1 records; they remain in platform secret storage.

## Row and payload split

D1 stores identifiers, relationships, statuses, compact JSON contracts, provenance, digests, and R2 references. Artifact content that is large or unstructured is written to R2 and represented by an immutable reference containing bucket, key, size, media type, and digest. Small content may use an inline form under the same artifact contract.

## Work v1 state

Work requests and workflow tasks are persisted with their dependencies and assignment references. Runs and worker assignments record execution state; Workstream checkout, lease, checkpoint, and audit records enforce scoped execution and recovery. Current state is reconstructed from those v8 records and the durable realtime event stream. The schema does not include the retired Goal/Phase/Attempt/ModelCall/Finding/Verification aggregate.

`worker_assignments.worker_type_id` identifies the logical Worker type; `workspace_worker_id` identifies the Workspace's local Worker slot. The clean v8 baseline stores the Cloud Workflow instance ID on `runs.workflow_instance_id` and limits Workstream execution policy to logical Worker type IDs. It has no external-execution side table or provider allowlist. Apply this baseline only to a fresh development database; it is not an upgrade migration for an existing database.

Human Product, Workspace Runtime, and Local Worker Protocol contracts have separate owners, endpoints, authentication, versions, and wire schemas. Keep one canonical schema source per boundary and generate language bindings from it. Shared domain IDs do not justify sharing transport envelopes.

See [Protocol Boundaries](../architecture/PROTOCOL_BOUNDARIES.md).
