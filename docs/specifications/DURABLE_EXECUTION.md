# Durable Conclave Execution

Phase 11 maps long-running Conclave runs to a Cloudflare Workflow named `conclave-run`. Workflows provide durable step checkpoints, retry boundaries, long sleeps, and external event waits. D1/R2 remain the application system of record; Workflow state is the execution checkpoint and control plane, not a replacement for persisted domain rows.

## Lifecycle

The Worker creates an instance with a deterministic ID derived from a validated idempotency key. The Workflow checkpoints these stages with `step.do`:

```text
intake -> wait for run control -> research -> planning -> implementation
  -> optional approval wait -> verification -> completed
```

Each checkpoint returns the complete small state needed by the next stage. A Workflow replay therefore does not depend on module-level mutable state, wall-clock values, or an in-memory task cursor. Step retries are bounded and use exponential backoff.

## Controls

The Worker exposes the following control surface:

- `POST /api/runs` creates or retrieves an instance by `Idempotency-Key`;
- `GET /api/runs/:id` reads the durable instance status and output;
- `POST /api/runs/:id/pause` and `/resume` use Workflow instance controls;
- `POST /api/runs/:id/restart` restarts from the durable Workflow state;
- `POST /api/runs/:id/events` sends validated `run-control` or `run-approval` events.

The first external `run-control` event must be `continue` or `cancel`. A run configured with `requireApproval` waits on `run-approval` for up to 365 days. A rejected approval produces a durable cancelled result. Native pause/resume controls are separate from event waits: pausing suspends execution, while resuming allows the current step to continue.

## Idempotency and recovery

The API accepts only idempotency keys matching `[A-Za-z0-9_-]{1,80}` and uses `run-${key}` as the Workflow instance ID. Repeating a create request returns the existing instance if the deterministic create reports that the ID already exists. The Workflow performs side effects only inside named steps; a retry replays the cached step result or retries that step according to its policy.

External event payloads include an `eventId` and are validated again inside the Workflow. The event type is allowlisted at the API boundary and uses Workflow-compatible names (`run-control`, `run-approval`).

## Product boundary

The current Workflow is the durable execution coordinator and control surface. Forge model/runtime work is injected behind the orchestration adapters from earlier phases; the next integration step is to call the persisted Forge runner from the durable stage steps and record each checkpoint in D1/R2. Queues and Durable Objects are intentionally not configured: Workflow instance identity, retries, waits, pause/resume, and event delivery cover the current single-run coordination requirement.
