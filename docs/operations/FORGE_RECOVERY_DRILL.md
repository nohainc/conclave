# Forge recovery drill

This drill validates the P23 exit criteria against a deployed Cloud Worker,
Forge execution service, Agent Gateway, and Dart Agent Engine. It is separate
from the deterministic fixture tests, which run in CI without external
credentials.

## Preconditions

- Cloudflare Access protects the deployed Studio/Worker hostname.
- The test Workspace has one enrolled online Agent with three local Workers:
  Lead, Implementer, and Reviewer.
- The Workers resolve to the same Agent for `single_agent` mode, or to at
  least two Agents for `multi_agent` mode.
- The fixture repository is registered with the Project and has a known
  revision.
- `CONCLAVE_FORGE_CALLBACK_TOKEN` and the CI evidence token are configured in
  the deployment.
- The operator has a temporary authenticated Studio session or API client.

## Expected terminal sequence

The run is not complete until these records are present and correlated by the
same domain `runId`:

```text
GoalReceived
RunStarted
PhaseStarted(research)
PhaseStarted(planning)
PhaseStarted(implementation)
ForgeExecutionStarted(executionId)
ModelRequestSent / ModelResultAccepted
ArtifactCreated / FindingCreated / VerificationRecorded
ForgeCompleted(executionId, resultArtifactId)
CI evidence accepted (when required)
RunCompleted
```

Every model request/result must retain `goalId`, `runId`, `taskId`,
`attemptId`, `workerId`, and the selected plugin/version. Every runtime
operation must retain the repository, approval, command, exit code, and
artifact digest.

## Recovery scenarios

### Agent restart

1. Start a Forge run from Studio.
2. Stop the Agent Engine after an assignment is journaled.
3. Restart the Engine with the same Agent identity and journal directory.
4. Confirm Cloud reconciliation does not create a second active assignment.
5. Confirm the terminal result is delivered once and the run completes.

### Cloud/Forge service restart

1. Start a run and record its domain `runId` and `executionId`.
2. Restart the Worker or Forge service before the callback arrives.
3. Query `/status/{executionId}` and confirm D1 still reports the same
   execution record.
4. Confirm Workflow reconciliation receives the persisted terminal state.
5. Confirm the Workflow and Forge execution records have the same terminal
   status.

### Temporary network loss

1. Disconnect the Agent after assignment delivery.
2. Confirm the Agent enters reconnect/backoff without losing its journal.
3. Restore connectivity and confirm session replacement/reconciliation.
4. Confirm no duplicate write operation or duplicate terminal event occurs.

### Reviewer timeout

1. Run with a reviewer that does not return before the task timeout.
2. Confirm the attempt is failed with a worker/timeout failure class.
3. Confirm the run does not become completed while independent verification is
   missing.
4. Retry or reroute according to policy and record the new attempt separately.

## Sign-off evidence

Attach the ordered Run Event export, D1 Forge execution record, Agent journal,
runtime evidence artifacts, final diff, machine test evidence, and the final
completion report. A drill passes only when the final report names the
successful machine checks and every recovery scenario preserves correlation
and idempotency.
