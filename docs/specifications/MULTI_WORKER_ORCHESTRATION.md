# Multi-Worker Orchestration

**Status:** Proposed architecture  
**Scope:** Generic Core behavior used by Forge and future applications

## 1. Principle

Every Conclave AX role uses the same assignment architecture.

A Task does not hard-code "one model". It declares:
- Role;
- required Capabilities;
- input/output contract;
- verification requirements;
- an **Execution Policy**.

The Execution Policy decides whether the Task is performed by one Worker or by multiple independent Workers.

This means Research, Planning, Architecture, Implementation, Review, Verification, and other future roles can all use the same mechanism.

## 2. Why multiple Workers

The default should usually remain a single eligible Worker to control cost and latency.

Multiple Workers are valuable when:
- exploring architecture/design choices;
- requirements are ambiguous;
- risk is high;
- independent perspectives are important;
- one model may miss a class of issue;
- a decision benefits from competing implementations;
- verification policy requires provider diversity.

Multiple Workers increase diversity, not truth. Conclave must compare evidence rather than treating majority vote as correctness.

## 3. Execution Policy

A Task snapshots an Execution Policy such as:

```text
mode
minCandidates
maxCandidates
selectionStrategy
diversityRequirements
contextIsolation
budget
timeout
workspacePolicy
fallbackPolicy
```

Supported modes:

### single
One Worker executes the Task.

### parallel
N Workers execute the same Task independently. Their candidate results remain separate.

### synthesize
N independent candidates are created, then a Synthesizer Task produces a combined result supported by candidate evidence.

### compare_and_select
N independent candidates are created, then an Evaluator/Judge Task selects one according to an explicit rubric.

### competitive_implementation
N Implementers work in isolated workspaces. Their diffs/tests are compared, one candidate is selected, or a separate Integrator creates a combined implementation.

The same primitives are used for all modes: Task, Attempt, Artifact, Finding, Verification, Decision, Event.

## 4. Candidate attempts

Parallel execution must not create special untracked chat state.

Each Worker produces a separate immutable Attempt:

```text
Task
  +-- Attempt A -> Candidate A
  +-- Attempt B -> Candidate B
  +-- Attempt C -> Candidate C
```

Candidate outputs are Artifacts and structured protocol results.

Only an accepted candidate/synthesis may become the Task result used by downstream Tasks.

## 5. Synthesis and selection

Synthesis is itself ordinary Conclave work.

```text
Candidate A
Candidate B
Candidate C
    |
    v
Synthesis / Evaluation Task
    |
    v
Decision + accepted result
```

The synthesis/evaluation input includes:
- original Goal/Task;
- candidate structured results;
- candidate evidence/artifacts;
- explicit comparison rubric;
- known cost/latency where relevant.

The output must state:
- selected/combined conclusions;
- disagreements;
- evidence supporting the decision;
- rejected alternatives and why;
- unresolved uncertainty.

Core validates the decision but does not ask an LLM to secretly overwrite the candidate history.

## 6. Independence levels

Conclave records the kind of independence achieved:

1. **context independent** — same Worker/model, separate isolated session;
2. **worker independent** — different Worker configuration;
3. **model independent** — different model/version;
4. **provider independent** — different provider/model family;
5. **execution independent** — separate runtime/environment where relevant.

Policies can require a minimum level.

Example:
- normal review: worker independent;
- high-assurance security review: provider independent;
- exploratory design: model/provider diversity preferred but not mandatory.

A separate chat with the same model is useful but must not be represented as equivalent to a separate provider.

## 7. Role examples

### Research / architecture

Preferred multi-worker flow:

```text
Researcher A
Researcher B
Researcher C
     |
     v
Synthesizer
     |
     v
accepted research/design basis
```

This is the first ensemble mode to implement because Workers are read-only and parallelism is safe.

### Planning

Several Planners may propose plans. A separate Evaluator selects or synthesizes a dependency-valid plan before Core admits it.

### Review

Multiple Reviewers independently inspect the same implementation. Findings are merged by identity/scope and remain independently attributable.

Do not discard a blocker merely because most reviewers did not find it.

### Verification

Multiple reasoning Workers may interpret evidence, but executable checks remain authoritative machine evidence where available.

### Implementation

Parallel implementation is more complex. Implementers must never mutate the same checkout concurrently.

Each candidate uses an isolated workspace such as:
- Git worktree;
- temporary clone;
- isolated branch;
- sandboxed repository snapshot.

Candidate implementations are tested independently. An Evaluator selects one or an Integrator creates a new combined implementation in another isolated workspace.

## 8. Quality presets

Conclave AX should expose simple presets that compile into Execution Policies.

### Economy
- one Lead/Planner;
- one Researcher;
- one Implementer;
- one independent Reviewer;
- required executable checks.

### Balanced
- one Researcher normally;
- two Researchers/Architects when task is design-heavy, ambiguous, or risky;
- one Implementer;
- one independent Reviewer;
- optional second Reviewer for major findings.

### High Assurance
- at least two independent research/design candidates;
- explicit synthesis/evaluation;
- one or more implementation candidates depending risk/budget;
- at least two independent reviewers, preferably provider-diverse;
- strict executable verification;
- no silent waivers.

### Exploration
- multiple independent research/architecture proposals;
- synthesis with disagreements retained;
- optional competing implementation prototypes;
- optimized for solution quality/diversity rather than cost.

### Custom
User/project supplies per-role policies.

Presets are configuration, not separate orchestration code.

## 9. Cost-aware routing

Execution Policy includes a budget and preference order.

Examples:

```text
prefer subscription workers
max API spend: $2
max research candidates: 3
fallback to API only if local subscription worker unavailable
```

Cost accounting must distinguish:
- metered API cost;
- subscription-backed usage;
- local compute;
- external service cost;
- unknown cost.

Conclave may recommend a more expensive ensemble but must not exceed the configured budget without approval.

## 10. Anti-explosion rules

Multi-worker orchestration can recursively multiply calls, so Core enforces:
- maximum candidates per Task;
- maximum synthesis depth;
- maximum correction/re-review loops;
- run-level model-call budget;
- run-level cost/token/time budget;
- no automatic ensemble-of-ensembles unless explicitly configured;
- deterministic termination rules.

A Synthesizer is normally single-worker unless the policy explicitly requires independent synthesis review.

## 11. Generic invariant

The core invariant is:

> One Task may produce one or many candidate Attempts, but exactly one accepted Task result (or one explicit combined result) is admitted to the downstream graph.

This keeps the task graph deterministic while allowing broad model diversity.


## 12. Interactive web/cloud candidates

Interactive web/cloud workers participate in the same candidate model as every other transport.

Example:

```text
Architecture Task
  +-- Attempt A -> ChatGPT web worker
  +-- Attempt B -> Claude web worker
  +-- Attempt C -> another supported web worker
        |
        v
     Synthesizer
```

Conclave does not need direct provider API billing for these candidates when the user's subscription-backed web surface and Conclave connector support the work.

Web workers are particularly suitable for Research, Architecture, Planning proposals, Review, and Synthesis. Their availability may be interactive rather than continuously autonomous, so Execution Policy must allow waiting, notification, or fallback.

See [WEB_APP_WORKERS.md](WEB_APP_WORKERS.md).
