# Conclave Domain and Forge Workflow Specification

**Status:** Draft for Phase 0
**Version:** 0.1
**Scope:** Conclave Core and the first Conclave Forge workflow

This document is normative for the first implementation. It defines the domain vocabulary, ownership boundaries, lifecycle rules, evidence requirements, and the minimum Forge workflow. Provider-specific behavior, database schemas, and UI details are intentionally out of scope.

## 1. Operating model

Conclave receives a user message and turns it into a persistent **Goal**. A Goal is executed through one or more **Runs**. A Run is a stateful attempt to satisfy the Goal and is divided into ordered **Phases**. Phases contain dependent **Tasks**. A Task may be executed several times through separate **Attempts** by a selected **Worker**.

Workers produce **Artifacts** and structured results. Independent workers or executable tools produce **Findings** and **Verifications**. Conclave Core, not a worker, owns state transitions and records every material choice as a **Decision** and every transition as an **Event**.

The central invariant is:

> A Goal is complete only when its completion criteria are satisfied by accepted evidence and no blocking failure or unresolved blocking Finding remains.

Natural-language claims from workers are observations or proposals. They are never completion evidence by themselves.

## 2. Domain terms

### 2.1 Goal

A **Goal** is the durable user-owned outcome Conclave is asked to achieve. It contains:

- the original user message and normalized objective;
- project/repository context;
- explicit or inferred constraints and assumptions;
- completion criteria;
- a verification policy;
- lifecycle status and timestamps.

A Goal may have multiple Runs. A new Run is created when the user retries, resumes after a recoverable failure, or explicitly requests another execution. The Goal remains the same unless the user changes the desired outcome; a materially changed outcome creates a new Goal.

Goal statuses are `draft`, `ready`, `running`, `waiting`, `completed`, `failed`, `cancelled`, and `superseded`.

### 2.2 Run

A **Run** is one execution of a Goal under a specific plan, worker configuration, and verification policy snapshot. It is the unit of orchestration, cancellation, retry, audit, and final reporting.

A Run records its start reason, parent Run when applicable, current Phase, budgets, attempt counts, and terminal outcome. Only one Run for a Goal may be actively mutating the Goal at a time.

Run statuses are `queued`, `planning`, `active`, `waiting`, `succeeded`, `failed`, `cancelled`, and `expired`.

### 2.3 Phase

A **Phase** is a bounded stage of a Run with one purpose, entry conditions, exit criteria, and an ordered or dependency-based set of Tasks. A Phase may not be marked complete until all required Tasks and phase-level criteria are satisfied.

Forge uses these phases: `intake`, `research`, `planning`, `implementation`, `review`, `correction`, `verification`, and `reporting`.

Phase statuses are `pending`, `active`, `waiting`, `succeeded`, `blocked`, `failed`, `cancelled`, and `skipped`.

### 2.4 Task

A **Task** is the smallest independently assignable unit of work that has a clear input, output contract, completion criteria, and verification method. A Task belongs to one Phase and may depend on other Tasks in the same Run.

Each Task defines:

- objective and context references;
- required Role and Capability set;
- inputs and expected output types;
- dependency IDs;
- retry policy and resource budget;
- whether independent verification is required.

Task statuses are `pending`, `ready`, `assigned`, `running`, `review`, `succeeded`, `blocked`, `failed`, `cancelled`, and `superseded`.

### 2.5 Attempt

An **Attempt** is one concrete execution of a Task by one Worker. It has an immutable input snapshot, worker identity/version, start and end times, output references, usage data, and a terminal result.

An Attempt may end as `succeeded`, `rejected`, `timed_out`, `cancelled`, `errored`, or `abandoned`. A failed Attempt does not itself fail the Task if retry policy permits another Attempt. An Attempt cannot rewrite another Attempt's outputs.

### 2.6 Worker

A **Worker** is an execution participant behind a provider-independent adapter. It may be an AI model, coding agent, local runtime, CI runner, tool, or human reviewer.

A Worker has an identity, kind, adapter version, available Roles and Capabilities, permission boundary, trust/independence attributes, and operational limits. Worker credentials are referenced through secure configuration and are never part of task payloads or ordinary event data.

Workers propose results and actions. Core validates the response against the task contract and decides whether to accept it.

### 2.7 Role

A **Role** describes the responsibility a Worker performs in a workflow. Roles are workflow-facing and are not tied to a vendor. Initial Forge roles are:

- **Lead:** owns planning, delegation, synthesis, and the final completion recommendation.
- **Researcher:** inspects the repository and identifies relevant behavior, constraints, and risks.
- **Implementer:** changes the repository according to an accepted plan.
- **Reviewer:** independently evaluates implementation against the Goal and plan.
- **Verifier:** runs or interprets executable checks and confirms evidence sufficiency.

One Worker may support multiple Roles, but a review is not independent if it is performed by the same Worker context that produced the implementation under review.

### 2.8 Capability

A **Capability** is a typed operation a Worker can perform, such as repository inspection, file editing, patch creation, test execution, static analysis, or human approval. Capabilities include declared input/output contracts and required permissions.

Task routing requires all mandatory Capabilities and the requested Role. Core must reject or re-plan a task when no eligible Worker satisfies the requirements.

### 2.9 Artifact

An **Artifact** is a durable, addressable output or input relevant to a Run. Examples include repository snapshots, research notes, plans, patches, diffs, test output, screenshots, reports, and structured worker responses.

Every Artifact has an owner Run/Task/Attempt, media type, content digest, provenance, creation time, retention classification, and (when applicable) repository revision. Large content is stored externally; metadata and references remain in the system of record. Artifacts are immutable. A corrected output creates a new Artifact.

### 2.10 Finding

A **Finding** is a specific, reviewable observation that may prevent completion or improve quality. It must identify the affected scope, evidence, severity, source, and recommended disposition.

Finding severities are `blocker`, `major`, `minor`, and `note`. Finding statuses are `open`, `accepted`, `dismissed`, `fixed`, `reopened`, and `verified`.

Only `blocker` and `major` Findings designated by the verification policy block completion. A dismissal requires a Decision with rationale and, when required, user approval.

### 2.11 Verification

A **Verification** is a recorded evaluation of a completion criterion, Artifact, Task, Phase, or Run. It identifies the verifier, method, inputs, exact result, evidence references, and timestamp.

Verification methods include `executable_check`, `independent_review`, `policy_check`, `human_approval`, and `inconclusive`. A verification is `passed`, `failed`, `waived`, or `inconclusive`.

Verification is independent when the verifier has a separate Worker identity or isolated context and did not author the result being evaluated. Independence requirements come from the verification policy.

### 2.12 Decision

A **Decision** is an explicit, append-only record of a consequential orchestration choice. Examples include accepting a plan, selecting a Worker, retrying an Attempt, accepting or dismissing a Finding, waiving a check, reopening a Task, or declaring a Run complete.

Every Decision records the decider (Core, Worker proposal accepted by Core, or human), alternatives considered when relevant, rationale, evidence references, policy basis, and resulting state transition. Workers may propose Decisions; only authorized Core or human actors may commit them.

### 2.13 Event

An **Event** is an append-only fact that a domain change occurred. Events include Goal received, Run started, Task assigned, Attempt completed, Artifact created, Finding opened, Verification passed, Decision recorded, and terminal transitions.

Events are ordered within a Run, carry a schema version and correlation IDs, and reference the affected entity. Events are audit history, not the sole source of current state; current state must be reconstructable from persisted records plus ordered events.

## 3. Completion criteria and verification policy

Completion criteria are first-class records created with the Goal, not an unstructured string list. Each criterion has an ID, description, verification requirement, evidence references, and status. Core owns the criterion state and Forge supports at least:

- requested behavior is implemented;
- relevant tests are added or an explicit rationale records why not;
- repository checks required by the project pass;
- review has no unresolved blocking Findings;
- the change is represented by an inspectable Artifact (for example a diff);
- known risks and limitations are reported.

The verification policy specifies required roles, independence rules, minimum evidence, retry limits, timeout/budget limits, and approval requirements. A criterion may be marked `satisfied` only by accepted Verification evidence. Criteria may also be `failed`, `waived`, or `inconclusive`; `waived` requires an explicit Decision and cannot silently satisfy a mandatory criterion.

The Lead may recommend completion, but its report is advisory. Core requires an exact criterion-id mapping and proves each criterion independently before allowing the terminal state. Run completion requires all of the following:

1. every mandatory criterion is satisfied or explicitly approved as waived;
2. all required Tasks and Phases are successful;
3. no blocking Finding is open or reopened;
4. required independent review has passed;
5. required executable checks have passed, or a policy-authorized waiver exists;
6. a final report Artifact references the Goal, changes, evidence, unresolved risks, and Decisions;
7. Core records the completion Decision and terminal Event.

## 4. Failure, waiting, and cancellation

Failure is classified so the user can distinguish a bad result from an unavailable system:

- **Validation failure:** a response is malformed, incomplete, or violates the task contract. Reject the Attempt and retry if allowed.
- **Worker failure:** a Worker errors, times out, exceeds budget, or loses connectivity. Retry, reroute, or pause according to policy.
- **Task failure:** required Attempts are exhausted or the Task cannot meet its contract.
- **Verification failure:** evidence contradicts a criterion or a reviewer opens a blocking Finding. Create correction work or fail when no correction is possible.
- **Dependency failure:** a prerequisite Task or external system is unavailable. Keep the Run waiting when recoverable; otherwise fail with the dependency named.
- **Policy failure:** no permitted Worker, capability, budget, approval, or security permission exists. Fail without attempting an unauthorized action.
- **Cancellation:** the user or authorized system stops the Run. In-flight work is cancelled where possible and its partial outputs remain auditable.

`waiting` means progress is intentionally paused for a recoverable external condition, user answer/approval, rate limit, or scheduled retry. `failed` is terminal for that Run and must include a failure class, last safe state, evidence, and recovery suggestion. A failed Goal may be resumed through a new Run; a cancelled Run is never silently resumed.

## 5. Forge workflow

Forge is the first concrete workflow. It accepts a repository context plus a development Goal and returns a verified completion report or an explicit failure report.

### 5.1 Intake

1. Store the user message as the Goal's original request.
2. Resolve the Project, repository, branch/revision, permissions, and available Workers.
3. Normalize the request into objective, constraints, assumptions, and completion criteria.
4. Ask the user for clarification or approval if a safe interpretation is not possible.
5. Create a Run and record the policy snapshot.

Exit: the Goal is `ready`, has a concrete repository context, and has typed completion criteria.

### 5.2 Research

1. Assign a Researcher Task to inspect the repository, relevant history/configuration, and existing tests.
2. Collect research notes and executable observations as Artifacts.
3. Record risks, unknowns, and assumptions as Findings or Decisions.

Exit: the Lead has enough evidence to describe the affected area, constraints, and a proposed change; unresolved blockers pause the Run.

### 5.3 Planning

1. The Lead converts research into a dependency-ordered plan of small Tasks.
2. Core validates task contracts, required Capabilities, permissions, budgets, and dependencies.
3. Core records the accepted plan as a Decision and creates the implementation/review/verification Tasks.

Exit: every required Task has an owner Role, input/output contract, completion criteria, and verification method.

### 5.4 Implementation

1. Assign implementation Tasks to an eligible Implementer with the required repository permissions.
2. Give each Attempt an immutable repository revision/context snapshot.
3. Accept only contract-valid outputs: changed files/diff, explanation, tests added/updated, and known risks.
4. Persist patches and other outputs as Artifacts; do not treat chat text as the source of truth.

Exit: implementation Tasks succeed and an inspectable change Artifact exists, or the Run enters correction/failure handling.

### 5.5 Independent review

1. Assign a Reviewer that did not author the implementation, using an isolated context containing the Goal, plan, diff, and relevant evidence.
2. Require findings to identify exact scope, severity, rationale, and evidence.
3. Record a Verification for the review and open each Finding in Core.

Exit: review passes with no blocking Findings, or blocking Findings are converted into correction Tasks.

### 5.6 Correction loop

For each blocking Finding, Core creates or reopens a correction Task linked to the Finding. The Implementer produces a new Attempt and Artifact. The Reviewer re-checks the changed scope independently. A Finding becomes `verified` only after the re-review passes.

The loop is bounded by the Run's retry/iteration policy. If the bound is reached, the Run fails with the unresolved Findings and evidence; it does not report success merely because progress occurred.

### 5.7 Executable verification

1. Assign a Verifier or permitted runtime to execute the required tests/checks against the resulting revision.
2. Capture command identity, environment, revision, exit status, duration, and output as evidence.
3. Map each result to completion criteria and open Findings for failures or suspicious gaps.

Exit: all mandatory checks pass or a policy-authorized waiver is recorded.

### 5.8 Final verification and reporting

The Lead proposes completion. Core independently checks the completion matrix: criteria, required reviews, executable evidence, Finding status, policy constraints, and artifact provenance. If any item is missing, Core reopens the appropriate phase or fails the Run.

On success, Core records a completion Decision, emits the terminal Event, and creates a final report Artifact containing:

- the original Goal and interpreted outcome;
- revision and changed files;
- completed Tasks and phases;
- verification methods and evidence links;
- test/check results;
- resolved and unresolved Findings;
- assumptions, waivers, and remaining risks.

The user-facing result is `completed` only after this Decision is persisted.

## 6. Lifecycle invariant

The complete first-version lifecycle is:

```text
user message
  -> Goal + criteria
  -> Run + policy snapshot
  -> intake
  -> research evidence
  -> accepted plan
  -> implementation artifacts
  -> independent review
  -> correction/re-review loop (zero or more)
  -> executable verification
  -> final Core verification
  -> completion Decision + report Artifact
  -> verified completion or explicit failure
```

At every arrow, Core persists the state change and Event, validates worker output, and either advances, waits, retries, reopens work, or fails with a classified reason. No worker can advance a Run directly to completed.

## 7. Phase 0 acceptance checklist

Phase 0 is complete when a reviewer can answer these questions from the documentation alone:

- What durable object represents the user's request?
- What is the difference between a Run, Phase, Task, and Attempt?
- How are Workers selected without embedding provider logic in Core?
- What makes a review independent?
- What evidence is required for each completion criterion?
- Which Findings block completion and how are they resolved?
- What happens on malformed output, worker outage, failed tests, cancellation, or exhausted retries?
- Who owns each state transition and how is it audited?
- What exact sequence does Forge follow from user message to final report?
