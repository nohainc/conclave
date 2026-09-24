# V6 Multi-Workspace Stateless Fan-out

Research and review steps may run on auxiliary execution Workspaces when they
are stateless. The scheduler first freezes an immutable source snapshot:

- Checkpoint SHA;
- repository snapshot ID and revision, using a supported repository snapshot
  mechanism;
- explicitly authorized context artifact IDs.

Every stateless assignment receives that same snapshot metadata. Auxiliary
Workers never receive the Primary Workstream checkout path and cannot resolve a
mutable Primary checkout from an assignment. Stateful Workstream steps remain
bound to the Primary Workspace, managed checkout, and execution lease.

Fan-out candidates are filtered by capability and the Primary Workspace is
excluded. When independent providers are required, the plan must contain
distinct provider keys. Synthesis consumes the snapshot metadata from the
completed assignments, so it can verify that all evidence refers to the same
Checkpoint even if the Primary Workspace mutates while research is running.

Stale Checkpoint snapshots and unauthorized context artifacts are rejected
before dispatch. Snapshot IDs are opaque and are not filesystem paths.
