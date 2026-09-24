# ADR-009: Workstreams and Isolated Execution

**Status:** Proposed  
**Date:** 2026-09-24  
**Builds on:** ADR-008 / Architecture v5

## Context

Architecture v5 correctly separates Project collaboration from Workspace execution, but the implemented product still treats Chat as both:
- human conversation; and
- a potential execution trigger.

It also allows multiple mutating Runs to resolve the same registered repository path on one Workspace.

For a shared Project with several collaborators, this creates two product risks:

1. a normal discussion message may implicitly start AI work;
2. simultaneous AI work can corrupt or invalidate a shared checkout.

The Workspace runtime already contains strong primitives for safe filesystem access, command policy, and Git worktree creation. The missing architecture is a persistent collaboration/execution unit that owns isolated mutable state.

## Decision

Introduce **Workstream** as the unit of collaborative work inside a Project.

A Workstream contains:
- Discuss;
- Work;
- a Brief;
- Lead/access policy;
- default Workflow;
- Primary Workspace;
- Account policy;
- persistent managed checkout;
- checkpoint history.

### Discuss

Discuss is human collaboration only.

No Discuss message may create/resume a Goal or Run as a side effect.

### Work

AI execution begins only through an explicit Work Request.

A Work Request snapshots a versioned Workflow and creates a Run.

### Mutable state

A Workstream has one persistent managed Git checkout on one Primary Workspace.

Stateful Workflow steps:
- execute only on the Primary Workspace;
- require an exclusive execution lease;
- carry a fencing token and expected revision;
- are serialized per Workstream checkout.

Stateless read/research/review steps may run concurrently on other eligible Project Workspaces against immutable checkpoint context.

### Recovery

Successful stateful work creates a checkpoint.

Failed/cancelled stateful work restores the managed checkout to the previous checkpoint or marks it recovery-required if restoration fails.

## Consequences

### Positive
- human discussion cannot accidentally trigger paid or mutating AI work;
- multiple team members can work safely in parallel on different Workstreams;
- one machine can execute multiple isolated Workstreams;
- every AI iteration has explicit requester/workflow/account attribution;
- stateful work starts from a known revision;
- rollback and audit become straightforward;
- current SafeWorkspace/GitRepository worktree primitives are reused.

### Tradeoffs
- Workstream becomes a significant domain object;
- runtime must manage persistent checkouts and recovery;
- stateful concurrency is intentionally serialized within one Workstream;
- Workflow definitions need versioning;
- additional Durable Object/D1 coordination is required.

## Rejected alternatives

### Keep Chat and add a second nested AI Chat

Rejected because two nested generic Chats do not express different semantics strongly enough. Discuss and Work have different authorization and side-effect rules.

### One worktree per Run by default

Deferred because parallel mutating Runs inside one Workstream require merge/rebase semantics. v6 prefers one persistent checkout plus serialized mutation.

### Lock the Project's normal registered repository checkout

Rejected because it blocks unrelated Workstreams and risks leaving the user's normal repository dirty after failures.

### Allow stateful steps to run on arbitrary Project Workspaces

Rejected because mutable state would become distributed and require synchronization/merge semantics.

## Core invariant

> **A Workstream is the owner of one mutable execution history. Discuss is side-effect free; Work is explicit; stateful work is isolated and serialized.**
