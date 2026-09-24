# V6 Workstream Brief and Context Builder

Each Workstream has an editable structured Brief with four fields:

- purpose;
- current state;
- constraints;
- expected outcome.

The Brief is shared Workstream context, not an execution command. Editing it is
role-gated by Project/Workstream authorization and changes are auditable when
persisted by the Workstream API.

## Deterministic context assembly

The Work context builder assembles inputs in this fixed order:

1. Project instructions;
2. Brief purpose, state, constraints, and expected outcome;
3. current Checkpoint;
4. current Work Request;
5. explicitly selected Discuss references;
6. explicitly selected artifacts;
7. Workflow requirements.

Each input is normalized and bounded before assembly. References and artifacts
are included only when explicitly authorized and selected. The full discussion
transcript, unrelated Work Requests, and provider history are excluded by
default; provider history may be added only by an explicit session policy.

The resulting context is a read-only snapshot for scheduling and execution.
Stable ordering and bounded fields make repeated Work Requests reproducible as
the Workstream accumulates years of collaboration history.
