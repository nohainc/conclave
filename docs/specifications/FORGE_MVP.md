# Conclave Forge MVP

Forge is the first major workflow built on Conclave AX Core.

It accepts a repository context and a development goal, coordinates independent Workers, gathers executable evidence, and returns a verified completion report.

## Lifecycle

```text
repository inspection
  -> research
  -> optional independent research
  -> plan
  -> implementation
  -> independent review
  -> correction loop
  -> real tests/build checks
  -> verification
  -> completion report
```

## Architecture v3 execution boundary

Forge does not call model/provider APIs or local CLIs directly.

Every external action goes through:

```text
Cloud
  -> WorkerAssignment
  -> Conclave Agent Engine
  -> Worker Plugin
  -> Worker
  -> AI / CLI / tool / service
```

Repository operations and test execution are provided by Agent Engine/Worker Plugin capabilities, not a top-level Local Runtime product.

## Worker separation

Forge roles may include:
- Lead/Planner;
- Researcher;
- Implementer;
- Reviewer;
- Verifier;
- Test/CI Worker.

The provider/model is not part of workflow logic.

Workers are selected by role/capability/policy.

Implementation and independent review must not silently use the same Worker identity when policy requires independence.

## Context assembly

Workers receive bounded context assembled from:
- current Task;
- accepted prior Decisions/results;
- relevant Artifacts;
- repository evidence;
- Project instructions;
- explicit references.

Do not send entire Chat history blindly.

## Repository boundary

Write-capable work must execute through bounded Agent Engine/plugin permissions.

Examples:
- repository read/search;
- patch/write/delete;
- Git status/diff;
- tests/builds;
- command execution.

Each operation returns durable evidence.

## Review and correction

Blocking Findings reopen the relevant work.

The correction/re-review loop is bounded by policy.

Run completion is impossible while required verification or blocking Findings remain unresolved.

## Completion gate

Completion requires:
1. required independent review;
2. no unresolved blocking Finding;
3. passing machine evidence where applicable;
4. individually verified Goal criteria;
5. a valid CompletionResult;
6. persisted final report Artifact;
7. durable RunCompleted event.

AI statements alone are not machine evidence.

## Multi-worker execution

Forge uses the generic Execution Policy:
- single;
- parallel;
- synthesize;
- compare_and_select;
- competitive_implementation.

Candidate Attempts remain separate and auditable.

See [Multi-Worker Orchestration](MULTI_WORKER_ORCHESTRATION.md).
