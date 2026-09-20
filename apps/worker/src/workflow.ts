import {
  WorkflowEntrypoint,
  type WorkflowEvent,
  type WorkflowStep,
} from "cloudflare:workers";

export interface ConclaveWorkflowParams {
  readonly runId: string;
  readonly goalId: string;
  readonly idempotencyKey: string;
  readonly requireApproval?: boolean;
}

export interface ConclaveWorkflowCheckpoint {
  readonly runId: string;
  readonly goalId: string;
  readonly idempotencyKey: string;
  readonly stage:
    | "intake"
    | "research"
    | "planning"
    | "implementation"
    | "verification"
    | "completed"
    | "cancelled";
  readonly status: "active" | "waiting" | "completed" | "cancelled";
  readonly eventId?: string;
  readonly eventAction?: string;
}

interface RunControlEvent {
  readonly eventId: string;
  readonly action: "continue" | "cancel";
}

interface ApprovalEvent {
  readonly eventId: string;
  readonly approved: boolean;
}

const stepConfig = {
  retries: {
    limit: 3,
    delay: "5 seconds" as const,
    backoff: "exponential" as const,
  },
  timeout: "5 minutes" as const,
} as const;

function isRunControlEvent(value: unknown): value is RunControlEvent {
  if (typeof value !== "object" || value === null) return false;
  const record = value as Record<string, unknown>;
  return (
    typeof record.eventId === "string" &&
    (record.action === "continue" || record.action === "cancel")
  );
}

function isApprovalEvent(value: unknown): value is ApprovalEvent {
  if (typeof value !== "object" || value === null) return false;
  const record = value as Record<string, unknown>;
  return (
    typeof record.eventId === "string" && typeof record.approved === "boolean"
  );
}

export class ConclaveRunWorkflow extends WorkflowEntrypoint<
  Env,
  ConclaveWorkflowParams
> {
  override async run(
    event: WorkflowEvent<ConclaveWorkflowParams>,
    step: WorkflowStep,
  ): Promise<ConclaveWorkflowCheckpoint> {
    const params = event.payload;
    const started = await step.do(
      "checkpoint:intake",
      stepConfig,
      async () => ({
        runId: params.runId,
        goalId: params.goalId,
        idempotencyKey: params.idempotencyKey,
        stage: "intake" as const,
        status: "active" as const,
      }),
    );

    const controlEvent = await step.waitForEvent<RunControlEvent>(
      "wait for run control",
      { type: "run-control", timeout: "365 days" },
    );
    if (!isRunControlEvent(controlEvent.payload)) {
      throw new Error("Invalid run-control event payload");
    }
    if (controlEvent.payload.action === "cancel") {
      return step.do("checkpoint:cancelled", stepConfig, async () => ({
        ...started,
        stage: "cancelled" as const,
        status: "cancelled" as const,
        eventId: controlEvent.payload.eventId,
        eventAction: controlEvent.payload.action,
      }));
    }

    const research = await step.do(
      "checkpoint:research",
      stepConfig,
      async () => ({
        ...started,
        stage: "research" as const,
        status: "active" as const,
        eventId: controlEvent.payload.eventId,
        eventAction: controlEvent.payload.action,
      }),
    );
    const planning = await step.do(
      "checkpoint:planning",
      stepConfig,
      async () => ({
        ...research,
        stage: "planning" as const,
      }),
    );
    const implementation = await step.do(
      "checkpoint:implementation",
      stepConfig,
      async () => ({ ...planning, stage: "implementation" as const }),
    );

    if (params.requireApproval) {
      const approvalEvent = await step.waitForEvent<ApprovalEvent>(
        "wait for external approval",
        { type: "run-approval", timeout: "365 days" },
      );
      if (!isApprovalEvent(approvalEvent.payload)) {
        throw new Error("Invalid run-approval event payload");
      }
      if (!approvalEvent.payload.approved) {
        return step.do(
          "checkpoint:cancelled-after-approval",
          stepConfig,
          async () => ({
            ...implementation,
            stage: "cancelled" as const,
            status: "cancelled" as const,
            eventId: approvalEvent.payload.eventId,
            eventAction: "approval_rejected",
          }),
        );
      }
    }

    const verification = await step.do(
      "checkpoint:verification",
      stepConfig,
      async () => ({ ...implementation, stage: "verification" as const }),
    );
    return step.do("checkpoint:completed", stepConfig, async () => ({
      ...verification,
      stage: "completed" as const,
      status: "completed" as const,
    }));
  }
}
