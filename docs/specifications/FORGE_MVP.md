# Conclave Forge MVP

Forge is the first serious workflow built on Core. It accepts a repository context and a development goal, coordinates at least two independent AI workers, uses the Local Runtime for repository evidence, and returns a verified completion report.

## Lifecycle

```text
repository inspection
  -> Lead research
  -> optional independent research challenge
  -> validated plan
  -> implementation
  -> isolated independent review
  -> correction loop for blocking findings
  -> real repository tests/build checks
  -> final verification
  -> completion report
```

The workflow persists each model request/response, Attempt, Model Call, Artifact, and Run Event through `ForgePersistence`. It validates every model response through the versioned protocol before using it as workflow state.

## Model context assembly

Runtime evidence is not useful to a model as an identifier alone. Before every Forge model call, the orchestration context builder resolves referenced Artifact IDs through the Artifact Store and attaches bounded context items to `ModelRequest`:

```text
Artifact Store -> ContextBuilder -> ModelRequest.context[] -> provider adapter
```

Each item includes the Artifact ID, media type, actual content, original length, truncation status, and an estimated token count. The builder deduplicates IDs and enforces artifact-count, per-artifact character, total-character, and estimated-token limits. Missing artifacts fail closed rather than sending an unresolved reference. The persisted protocol request retains the Artifact IDs for provenance, while the provider receives the assembled content.

## Worker separation

The Lead owns research synthesis, planning, verification, and reporting. The Implementer changes the repository. The Reviewer performs the independent research challenge, review, and test-evidence interpretation. Forge rejects a configuration where the Reviewer and Implementer are the same Worker identity. The default Reviewer is the Lead, so the MVP works with two independent AI workers while still keeping implementation and review contexts separate.

The provider is not part of the workflow logic. OpenAI, Anthropic, local agents, or future adapters implement the existing `ModelWorker` interface.

## Repository boundary

Forge does not read or mutate a repository directly. It receives a `ForgeRuntimeAdapter` with three bounded capabilities:

- `inspect` returns repository research evidence;
- `apply` applies or records an implementation result;
- `test` runs the requested checks and returns executable evidence.

The Phase 9 Local Runtime is the intended production implementation of this adapter. It must use approved `read_file`, `search`, `write_file`, `patch_file`, `delete_file`, Git, check, and build operations and return the resulting evidence with its content digest, command, revision, and exit status.

Implementation has two explicit execution modes:

1. In model-proposal mode, the Implementer returns a validated `ImplementationResult` containing concrete file operations. Forge passes those operations to `runtime.apply`; a summary or changed-file list without operations is rejected.
2. In agent-execution mode, an implementation agent receives a bounded runtime interface and performs approved operations itself. The host records each operation and evidence, then supplies Forge with the resulting implementation and runtime evidence. The agent may execute; the model result alone may only propose.

## Review and correction

If research reports risks, Forge asks the Reviewer for a second research result before planning. If the independent review requests changes, every blocking Finding enters the verification gate, the Implementer receives a correction task, the runtime applies the new result, and the Reviewer re-reviews it. The loop is bounded by `maxReviewLoops`; exhaustion fails the Run with the unresolved Finding IDs.

## Completion gate

Forge uses the `high` verification policy for the MVP. Completion requires:

1. a passing independent review;
2. no unresolved blocking Finding;
3. passing executable test evidence;
4. an individually passing VerificationResult for every Goal criterion;
5. a CompletionResult marked `completed` with exactly the Goal criterion IDs and no unresolved Finding IDs;
6. a final report Artifact containing the machine evidence and interpreted TestResult;
7. a persisted final report Artifact and `RunCompleted` Event.

AI statements such as “tests pass” are not enough. Each criterion must be verified by Core against persisted evidence returned by the runtime adapter; the Lead cannot mark an unverified criterion complete.
