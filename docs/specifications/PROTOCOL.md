# Conclave Protocol

**Version:** `0.1`

The protocol is the only accepted boundary between untrusted worker/model output and Core state. Every message is a strict JSON object with this envelope:

```json
{
  "protocol": "conclave.protocol",
  "version": "0.1",
  "messageId": "message-1",
  "goalId": "goal-1",
  "runId": "run-1",
  "workerId": "worker-1",
  "createdAt": "2026-09-21T10:00:00.000Z",
  "messageType": "...",
  "payload": {}
}
```

The runtime schemas live in `@conclave/protocol`. They reject the wrong version, unknown fields, missing fields, invalid enum values, invalid timestamps, and malformed nested payloads. TypeScript types are inferred from those schemas and are not a substitute for parsing.

## Message contracts

- `PlanRequest` / `PlanResult` — turn a Goal and repository context into dependency-ordered Phases and Tasks.
- `TaskRequest` / `TaskResult` — assign one typed Task and report its accepted output references.
- `ResearchResult` — repository observations, relevant paths, evidence, and risks.
- `ImplementationResult` — a proposed revision, changed files, explicit `write_file`, `patch_file`, or `delete_file` operations, requested tests, artifacts, and risks. A successful result must contain at least one proposed operation; a summary alone is never executable.
- `ReviewResult` — independent review outcome, typed Findings, and explicit `resolvedFindingIds` for fixes the reviewer accepts after re-review.
- `TestResult` — executable check outcomes tied to a revision and evidence Artifacts.
- `VerificationResult` — criterion-level verification method, outcome, rationale, and evidence.
- `DecisionResult` — a proposed state decision with rationale and explicit transitions.
- `CompletionResult` — criterion matrix, final report Artifact, unresolved Findings, and remaining risks. It is a recommendation; Core independently checks that the matrix exactly matches the Goal's first-class criteria and that every criterion is verified.

`PlanRequest` and `TaskRequest` are worker inputs. The remaining contracts are worker outputs. `ModelResultSchema` is the union used when the expected output type is selected dynamically.

## Admission rule

Core accepts only the return value of `admitModelResult(input: unknown)`. A parse failure is a validation failure: the Attempt is rejected and may be retried or rerouted under the Run policy. No raw model object may be persisted as a state transition or used to mark a Task, Phase, Run, or Goal complete.

After parsing, orchestration validates response correlation against the active request: `goalId`, `runId`, `workerId`, expected message type, and task ID must all match. Task-scoped result payloads carry their `taskId`; a syntactically valid result from another run or task is rejected. Forge and the two-model runner retry validation failures up to their configured attempt limit, persist each rejected Attempt, and emit a retry event before failing the task when the limit is exhausted.
