# V7 Failure and Security Acceptance Coverage

This coverage extends the V7 Cloud-to-Workspace assignment acceptance test. It
records which adversarial and recovery behaviors have executable regression
coverage and keeps known integration limits visible. Tests assert safe failure,
idempotent recovery, or preservation of the Workspace security boundary; they
do not add token or cost Usage accounting.

## Cloud inventory recovery

`apps/cloud/test/v7-inventory-recovery.acceptance.test.ts` uses SQLite and the
production `WorkspaceGateway.recordWorkerInventory` path to verify:

- duplicate full snapshots are idempotent;
- duplicate `workspace.hello` messages safely update facts and receive an ack;
- omission from a full snapshot creates a stable removal tombstone;
- a reconnect snapshot at the same local revision restores inventory;
- restoration does not re-enable Cloud scheduling;
- another Workspace cannot replace the owning Workspace's Worker ID;
- malformed entries do not count as reported Workers and therefore cannot
  suppress tombstoning of an omitted Worker.

The test runs in the dedicated V7 migration-safety CI job beside
`v7-runtime-e2e.acceptance.test.ts`.

## Existing failure and security regression suites

| Behavior | Regression coverage |
| --- | --- |
| Reconnect retries, repeated disconnect recovery, assignment replay/deduplication, cancellation acknowledgement | `apps/host/test/cloud_connection_test.dart` |
| Stale socket close after reconnect; runtime and assignment identity matching | `apps/cloud/test/workspace-gateway.test.ts`, `apps/cloud/test/host-gateway.test.ts` |
| Stateful lease monotonic fencing and stale token rejection | `apps/cloud/test/workstream-coordinator.test.ts`, `apps/host/test/workstream_security_acceptance_test.dart` |
| Adapter crash/error framing, process-tree cancellation, bounded output and secret redaction | `apps/host/test/worker_executor_test.dart`, `apps/host/test/process_tree_test.dart` |
| Removing a local Worker cancels its queued and running child assignments before tombstoning/deleting its credentials | `apps/host/test/worker_executor_test.dart`, `apps/host/test/configured_worker_registry_test.dart` |
| Adapter tampering, traversal, wrong type/platform, revoked key/digest, permission ceiling and rollback | `apps/host/test/v7_adapter_admission_test.dart`, `apps/host/test/v7_adapter_package_store_test.dart`, `apps/host/test/trust_policy_test.dart` |
| Workstream CWD/path traversal and hostile assignment paths | `apps/host/test/workstream_security_acceptance_test.dart`, `apps/host/test/workstream_path_test.dart`, `apps/host/test/v7_runtime_execution_acceptance_test.dart` |
| Missing/outdated prerequisites and readiness refresh | `apps/host/test/adapter_prerequisite_test.dart`, `apps/host/test/local_worker_setup_test.dart` |
| App release update defers while active assignments exist | `apps/host/test/self_update_test.dart` |
| Explicit cross-user/project authorization and Worker scheduling constraints | `apps/cloud/test/v7-scheduler.test.ts`, `apps/cloud/test/v7-runtime-e2e.acceptance.test.ts` |

The actual V7 execution test remains the end-to-end check for signed package
admission, local Worker resolution, ID-only Workstream CWD, progress, result
persistence, and the absence of V6 candidate reads.

## Limits

The tests above are deterministic local acceptance tests. They do not simulate
operating-system power loss, a real provider expiring credentials mid-request,
or a signed production Cloud release deployment. Those scenarios still require
platform/release-environment acceptance. A provider or CLI failure during an
assignment is expected to fail the assignment with a bounded, redacted error;
recovery requires a later eligible assignment after local authentication or
prerequisites are restored.
