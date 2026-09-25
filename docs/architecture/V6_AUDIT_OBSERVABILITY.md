# V6 Audit and Observability

Conclave Core and Cloud maintain operational auditability and health telemetry without monetary or token accounting. Operational history is tracked via immutable audit records and execution diagnostic metrics.

## Audit

### Workstream Audit Log
Workstream audit records (`workstream_audit_log`) cover all lifecycle and state transitions within a Workstream:
- `discussion.moderated`: Discussion messages moderated or hidden.
- `work_request.created`: New Work Request submitted.
- `workflow.selected`: Workflow definition/version selected for execution.
- `checkout.provisioned`: Workstream worktree checkout provisioned on a Workspace Host.
- `checkout.recovered`: Workstream worktree checkout recovered from previous execution state.
- `lease.acquired`: Exclusive execution lease acquired by a runner.
- `lease.released`: Execution lease released upon completion or failure.
- `checkpoint.created`: Git checkpoint commit created following verified work.
- `integration.updated`: Pull request / branch integration updated or published.

### Configured Worker Audit Log
Configured Worker lifecycle events (`configured_worker_audit_log`) use stable actions:
- `worker.created`: Configured Worker defined by its owner.
- `worker.updated`: Configured Worker configuration or default model updated.
- `worker.revoked`: Configured Worker revoked.
- `worker.workspace.bound`: Worker bound to an execution Workspace.
- `worker.workspace.unbound`: Worker unbound from an execution Workspace.
- `worker.credential.setup_requested`: Credential setup initiated for a Workspace.
- `worker.credential.ready`: Local credential verified and marked ready.
- `worker.credential.revoked`: Local credential revoked.

## Metrics & Observability

### Workstream Execution Metrics
The Workstream observability model (`workstream_observability_metrics`) records:
- Queue wait time in milliseconds;
- Stateful execution duration in milliseconds;
- Checkout recovery attempts and successes;
- Checkpoint rollback attempts and successes;
- Workspace activity samples.

These metrics enable real-time tracking of queue wait, recovery rate, failed rollback rate, and Workspace utilization without reconstructing state from raw logs.

### Configured Worker Observability
Configured Worker observability (`configured_worker_observability_metrics`) records runtime diagnostic samples:
- Readiness status (`ready` / `not ready`);
- Package installation status (`ready`, `installing`, `failed`);
- Credential status (`ready`, `missing`, `expired`);
- Permissions status (`ready`, `pending_grant`);
- Active assignment counts and concurrency utilization;
- Authentication failure signals;
- Package convergence latency in milliseconds.

Configured Worker health, diagnostic binding samples, and audit trail are exposed via `GET /api/workers/observability`.
