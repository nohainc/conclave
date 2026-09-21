import {
  WorkflowEntrypoint,
  type WorkflowEvent,
  type WorkflowStep,
} from "cloudflare:workers";
import {
  parseMachineCheckEvidence,
  type MachineCheckEvidence,
} from "@conclave/protocol";

export interface ConclaveWorkflowParams {
  readonly runId: string;
  readonly goalId: string;
  readonly idempotencyKey: string;
  readonly organizationId?: string;
  readonly repositoryId?: string;
  readonly revision?: string;
  readonly requireApproval?: boolean;
  readonly requireCiEvidence?: boolean;
  readonly startPaused?: boolean;
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
    | "cancelled"
    | "failed"
    | "needs_input";
  readonly status: "active" | "waiting" | "completed" | "cancelled" | "failed";
  readonly eventId?: string;
  readonly eventAction?: string;
  readonly machineEvidence?: Pick<
    MachineCheckEvidence,
    | "evidenceId"
    | "source"
    | "externalRunId"
    | "revision"
    | "workflow"
    | "conclusion"
    | "checks"
    | "coveragePercent"
    | "previewUrl"
    | "smokeTests"
    | "healthChecks"
    | "observedAt"
  >;
  readonly executionId?: string;
  readonly executionStatus?:
    "started" | "completed" | "failed" | "cancelled" | "needs_input";
  readonly resultArtifactId?: string;
  readonly failureReason?: string;
}

interface ForgeExecutionService {
  fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response>;
}

type ExecutionEnv = Env & {
  readonly CONCLAVE_FORGE_EXECUTION?: ForgeExecutionService;
};

interface RunControlEvent {
  readonly eventId: string;
  readonly action: "continue" | "cancel";
}

interface ApprovalEvent {
  readonly eventId: string;
  readonly approved: boolean;
}

type MachineEvidenceEvent = MachineCheckEvidence;

interface ForgeTerminalEvent {
  readonly eventId: string;
  readonly runId: string;
  readonly executionId: string;
  readonly status: "completed" | "failed" | "cancelled" | "needs_input";
  readonly resultArtifactId?: string;
  readonly error?: string;
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

function isForgeTerminalEvent(value: unknown): value is ForgeTerminalEvent {
  if (typeof value !== "object" || value === null) return false;
  const record = value as Record<string, unknown>;
  return (
    typeof record.eventId === "string" &&
    typeof record.runId === "string" &&
    typeof record.executionId === "string" &&
    (record.status === "completed" ||
      record.status === "failed" ||
      record.status === "cancelled" ||
      record.status === "needs_input") &&
    (record.resultArtifactId === undefined ||
      typeof record.resultArtifactId === "string") &&
    (record.error === undefined || typeof record.error === "string")
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

    let controlEvent: RunControlEvent | undefined;
    if (params.startPaused) {
      const event = await step.waitForEvent<RunControlEvent>(
        "wait for initial run control",
        { type: "run-control", timeout: "365 days" },
      );
      if (!isRunControlEvent(event.payload)) {
        throw new Error("Invalid run-control event payload");
      }
      controlEvent = event.payload;
    }
    if (controlEvent?.action === "cancel") {
      return step.do("checkpoint:cancelled", stepConfig, async () => ({
        ...started,
        stage: "cancelled" as const,
        status: "cancelled" as const,
        eventId: controlEvent.eventId,
        eventAction: controlEvent.action,
      }));
    }

    const research = await step.do(
      "checkpoint:research",
      stepConfig,
      async () => ({
        ...started,
        stage: "research" as const,
        status: "active" as const,
        ...(controlEvent
          ? { eventId: controlEvent.eventId, eventAction: controlEvent.action }
          : {}),
      }),
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
            ...research,
            stage: "cancelled" as const,
            status: "cancelled" as const,
            eventId: approvalEvent.payload.eventId,
            eventAction: "approval_rejected",
          }),
        );
      }
    }

    const execution = await step.do("forge:execute", stepConfig, async () => {
      const service = (this.env as ExecutionEnv).CONCLAVE_FORGE_EXECUTION;
      if (!service) {
        throw new Error(
          "Forge execution service is not configured; refusing to complete a checkpoint-only run",
        );
      }
      const response = await service.fetch(
        "https://conclave.internal/execute",
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(params),
        },
      );
      if (!response.ok) {
        throw new Error(
          `Forge execution failed with status ${response.status}`,
        );
      }
      const body = (await response.json()) as { executionId?: unknown };
      if (typeof body.executionId !== "string") {
        throw new Error("Forge execution returned no executionId");
      }
      return {
        ...research,
        executionId: body.executionId,
        executionStatus: "started" as const,
      };
    });
    let forgeTerminal: ForgeTerminalEvent;
    while (true) {
      const terminalEvent = await step.waitForEvent<ForgeTerminalEvent>(
        "wait for Forge terminal result",
        { type: "forge-terminal", timeout: "365 days" },
      );
      if (!isForgeTerminalEvent(terminalEvent.payload)) {
        throw new Error("Invalid Forge terminal event payload");
      }
      if (
        terminalEvent.payload.runId !== params.runId ||
        terminalEvent.payload.executionId !== execution.executionId
      ) {
        throw new Error("Forge terminal event does not match this run");
      }
      forgeTerminal = await step.do(
        `forge:terminal:${terminalEvent.payload.eventId}`,
        stepConfig,
        async () => terminalEvent.payload,
      );
      if (forgeTerminal.status !== "needs_input") break;
    }

    if (forgeTerminal.status !== "completed") {
      return step.do("checkpoint:forge-terminal", stepConfig, async () => ({
        ...execution,
        stage:
          forgeTerminal.status === "failed"
            ? ("failed" as const)
            : ("cancelled" as const),
        status:
          forgeTerminal.status === "failed"
            ? ("failed" as const)
            : ("cancelled" as const),
        executionStatus: forgeTerminal.status,
        ...(forgeTerminal.error ? { failureReason: forgeTerminal.error } : {}),
        ...(forgeTerminal.resultArtifactId
          ? { resultArtifactId: forgeTerminal.resultArtifactId }
          : {}),
      }));
    }

    const planning = await step.do(
      "checkpoint:planning",
      stepConfig,
      async () => ({
        ...execution,
        stage: "planning" as const,
      }),
    );
    const implementation = await step.do(
      "checkpoint:implementation",
      stepConfig,
      async () => ({ ...planning, stage: "implementation" as const }),
    );

    let machineEvidence: MachineEvidenceEvent | undefined;
    if (params.requireCiEvidence !== false) {
      const ciEvent = await step.waitForEvent<MachineEvidenceEvent>(
        "wait for machine CI evidence",
        { type: "ci-evidence", timeout: "365 days" },
      );
      try {
        machineEvidence = parseMachineCheckEvidence(ciEvent.payload);
      } catch (error) {
        throw new Error(
          `Invalid CI evidence: ${error instanceof Error ? error.message : "unknown"}`,
        );
      }
      if (machineEvidence.conclusion !== "success") {
        throw new Error(
          `Machine checks concluded ${machineEvidence.conclusion}`,
        );
      }
      const evidenceCheckpoint = await step.do(
        "checkpoint:machine-evidence",
        stepConfig,
        async () => ({
          ...implementation,
          stage: "implementation" as const,
          machineEvidence,
        }),
      );
      machineEvidence = evidenceCheckpoint.machineEvidence;
    }

    const verification = await step.do(
      "checkpoint:verification",
      stepConfig,
      async () => ({
        ...implementation,
        stage: "verification" as const,
        executionStatus: "completed" as const,
        ...(forgeTerminal.resultArtifactId
          ? { resultArtifactId: forgeTerminal.resultArtifactId }
          : {}),
        ...(machineEvidence ? { machineEvidence } : {}),
      }),
    );
    return step.do("checkpoint:completed", stepConfig, async () => ({
      ...verification,
      stage: "completed" as const,
      status: "completed" as const,
      executionStatus: "completed" as const,
    }));
  }
}
