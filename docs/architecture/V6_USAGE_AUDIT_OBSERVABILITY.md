# V6 Usage, Audit, and Observability

Usage facts are attributed to the complete Workstream iteration:

- Project;
- Workstream and Work Request;
- requester;
- execution Workspace and Workspace owner;
- Worker;
- AI Account and Account owner;
- Workflow version;
- input/output tokens, cost, and duration.

Usage dimensions come from immutable assignment snapshots. Callers cannot
replace requester, Workspace, Worker, Account, or owner dimensions at record
time.

## Audit

Workstream audit records cover discussion moderation when applicable, Work
Request creation, Workflow and Account selection, checkout provision/recovery,
lease acquisition/release, checkpoint creation, and integration updates.

## Metrics

The observability read model records queue wait, stateful duration, checkout
recovery attempts/successes, rollback attempts/successes, and Workspace sample
activity. These support queue wait, recovery rate, failed rollback rate, and
Workspace utilization reports without reconstructing state from raw logs.
