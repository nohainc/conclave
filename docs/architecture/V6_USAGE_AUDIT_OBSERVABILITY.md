# V6 Usage, Audit, and Observability

Usage facts are attributed to the complete Workstream iteration:

- Project;
- Workstream and Work Request;
- requester;
- execution Workspace and Workspace owner;
- Worker;
- configured Worker;
- Worker Type;
- logical external identity and credential owner (internal attribution);
- Workflow version;
- input/output tokens, cost, and duration.

Usage dimensions come from immutable assignment snapshots. Callers cannot
replace requester, Workspace, Worker, Worker Type, credential owner, Account,
or owner dimensions at record time.

Configured Worker usage is exposed through `GET /api/workers/observability`,
which also returns the latest Workspace binding samples and the audit trail.

## Audit

Workstream audit records cover discussion moderation when applicable, Work
Request creation, Workflow and Worker selection, checkout provision/recovery,
lease acquisition/release, checkpoint creation, and integration updates.

Configured Worker lifecycle events use stable actions for creation, update,
revocation, Workspace binding changes, and credential setup/readiness/revocation.
Runtime reports append immutable binding samples rather than overwriting the
diagnostic history.

## Metrics

The observability read model records queue wait, stateful duration, checkout
recovery attempts/successes, rollback attempts/successes, and Workspace sample
activity. These support queue wait, recovery rate, failed rollback rate, and
Workspace utilization reports without reconstructing state from raw logs.
Configured Worker samples additionally support ready/partial/offline binding
counts, authentication-failure counts, package convergence latency, and
assignment utilization by Worker.
