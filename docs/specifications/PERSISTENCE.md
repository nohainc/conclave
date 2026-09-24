# Persistence Contracts

Architecture v5 uses D1 as the structured system of record and R2 for large artifact payloads. Development databases are initialized from the clean [0001_conclave_v5.sql](../../apps/cloud/migrations-v5/0001_conclave_v5.sql) baseline. The v4 baseline remains in Git history only. Core accesses storage only through the interfaces in `@conclave/persistence`; it does not issue D1 queries directly.

Project-scoped history derives authorization from Project membership. Execution
Workspaces are user-owned and are connected to Projects only through explicit
Workspace Project Grants. No compatibility triggers or views preserve the v4
collaborative Workspace model.

## Row and payload split

D1 stores identifiers, relationships, statuses, compact JSON contracts, provenance, digests, and R2 references. Artifact content that is large or unstructured is written through `ArtifactPayloadStore` and represented by an immutable R2 reference containing bucket, key, size, media type, and digest. Small content may use the inline form under the same interface.

Credentials and secrets are not represented by these records. They remain in platform secret storage.

## Reconstruction contract

`RunRepository.loadAggregate(runId)` returns all persisted rows needed to reconstruct a Goal/Run: phases, tasks, dependencies, attempts, model calls, findings, verifications, artifacts, events, and usage. `reconstructRun` validates the Goal/Run relationship and requires Run Events to form a contiguous sequence beginning at `1`. It returns the aggregate with events in sequence order.

This makes an incomplete or cross-run event stream a persistence error rather than a silently partial run. Current row state and ordered audit history are both required for a complete reconstruction.
