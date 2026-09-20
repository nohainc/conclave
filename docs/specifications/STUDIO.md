# Conclave Studio

Conclave Studio is the operational UI for observing and controlling a Conclave run. Chat is an entry point for creating a goal, not the primary representation of work. The run dashboard is the source of truth for what is active, waiting, blocked, verified, or complete.

## Phase 8 surface

The first Studio surface contains:

- project switcher with repository and branch context;
- goal creation with an objective and revision;
- a live execution tree grouped by phase and task;
- task details showing worker, dependencies, progress, tokens, and cost;
- an ordered run timeline built from run events;
- findings and their severity/status;
- artifacts and evidence attached to the run;
- model calls with worker, model, duration, tokens, cost, and status;
- worker registry visibility and capability-based routing;
- pause, resume, cancel, retry, and approval entry points.

The current app uses an in-memory `StudioSnapshot` so the interaction model can be validated before the Cloud API is wired. The snapshot mirrors persisted domain records and is intentionally behind replaceable UI state. Production data must come from the reconstructed run aggregate and ordered events; the UI must not infer authoritative state from model text.

## Control semantics

Controls are commands against Core, not local edits to the graph:

| Studio action | Core command | Required result |
| --- | --- | --- |
| Pause | pause run | no new attempts start; active work is allowed to checkpoint |
| Resume | resume run | scheduler may start eligible tasks |
| Cancel | cancel run | run enters terminal cancellation and pending work is not started |
| Retry | retry task | a new attempt is created within policy/budget limits |
| Approve | record decision | the required human approval evidence is persisted |
| Create goal | create goal and run | a goal/run event sequence is returned |

Every command must be idempotent, permission-checked, and reflected back through events. A disabled or stale control must show why it is unavailable rather than silently failing.

## Information hierarchy

1. Run status and the next action are visible at the top of the page.
2. The execution tree shows phase/task progression and is the main navigation surface.
3. Selecting a task reveals its worker, dependencies, attempts, usage, findings, and controls.
4. Timeline, artifacts, model calls, and approvals provide evidence for review without hiding it in chat.

## Integration boundary

The UI adapter should expose a `RunStore` with reads for projects, workers, run aggregates, artifacts, findings, model calls, and events, plus commands for goal creation and run control. Flutter platform services remain behind interfaces so the same Studio codebase can run on desktop and web.
