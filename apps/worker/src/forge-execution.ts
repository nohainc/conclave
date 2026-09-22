import type {
  ArtifactRecord,
  GoalRecord,
  RunRecord,
} from "@conclave/persistence";
import {
  D1PersistenceRepositories,
  R2ArtifactStore,
  ThresholdArtifactStore,
  type D1DatabaseLike,
} from "@conclave/persistence";
import type {
  ExecutionEnvironment,
  WorkerRegistry,
  WorkerRequirement,
  WorkerResource,
  WorkerExecutionBinding,
  ExecutionChannel,
  WorkerExecutor,
  WorkerExecutionRequest,
  WorkerExecutionResult,
  WorkerAvailability,
  WorkerType,
  WorkerCostMetadata,
} from "@conclave/core";
import {
  executeForgeGoal,
  type ForgePersistence,
  type ForgeRuntimeAdapter,
  type ForgeRuntimeEvidence,
} from "@conclave/orchestration";
import {
  parseRuntimeOperationRequest,
  type ImplementationOperation,
} from "@conclave/protocol";
import {
  dispatchTaskAssignment,
  type AssignmentDispatcherEnv,
  type DispatchAssignmentResult,
} from "./assignment-dispatcher.js";

interface ForgeExecutionEnv {
  readonly CONCLAVE_DB: D1DatabaseLike;
  readonly CONCLAVE_ARTIFACTS: R2Bucket;
  readonly CONCLAVE_ARTIFACT_BUCKET_NAME?: string;
  readonly CONCLAVE_API_BASE_URL?: string;
  readonly CONCLAVE_API?: Fetcher;
  readonly CONCLAVE_FORGE_CALLBACK_TOKEN?: string;
  readonly CONCLAVE_TEST_COMMAND?: string;
  readonly CONCLAVE_AGENT_GATEWAY?: DurableObjectNamespace;
}

interface ForgeExecutionContext {
  readonly executionId: string;
  readonly runId: string;
  readonly taskId: string;
  readonly goalId: string;
  readonly organizationId: string;
  readonly projectId: string;
  readonly repositoryId: string;
  readonly revision: string;
}

interface ForgeExecutionRecord {
  readonly executionId: string;
  readonly runId: string;
  readonly status:
    "started" | "completed" | "failed" | "cancelled" | "needs_input";
  readonly resultArtifactId?: string;
  readonly error?: string;
  readonly updatedAt: string;
}

function forgeExecutionRecord(
  row: Record<string, unknown>,
): ForgeExecutionRecord {
  return {
    executionId: String(row.execution_id),
    runId: String(row.run_id),
    status: String(row.status) as ForgeExecutionRecord["status"],
    ...(row.result_artifact_id
      ? { resultArtifactId: String(row.result_artifact_id) }
      : {}),
    ...(row.error ? { error: String(row.error) } : {}),
    updatedAt: String(row.updated_at),
  };
}

export function assertSingleAgentForgeBindings(
  bindings: readonly WorkerExecutionBinding[],
  agentIds: ReadonlyMap<string, string>,
): void {
  if (bindings.length !== 3) {
    throw new Error(
      "Single-agent Forge requires lead, implementation, and review workers",
    );
  }
  if (
    bindings.some(({ connection }) => connection.transport !== "local_agent")
  ) {
    throw new Error(
      "Single-agent Forge does not permit direct cloud model workers",
    );
  }
  const resolvedAgentIdList = bindings
    .map(({ worker }) => agentIds.get(worker.id))
    .filter((id): id is string => Boolean(id));
  if (resolvedAgentIdList.length !== bindings.length) {
    throw new Error(
      "Single-agent Forge requires every worker to resolve to an agent",
    );
  }
  const resolvedAgentIds = new Set(resolvedAgentIdList);
  const uniqueAgentCount = [...resolvedAgentIds].length;
  if (uniqueAgentCount !== 1) {
    throw new Error(
      "Single-agent Forge requires all workers to run on one Agent",
    );
  }
}

export function assertMultiAgentForgeBindings(
  bindings: readonly WorkerExecutionBinding[],
  agentIds: ReadonlyMap<string, string>,
): void {
  if (bindings.length < 3) {
    throw new Error(
      "Multi-agent Forge requires lead, implementation, and review workers",
    );
  }
  if (
    bindings.some(({ connection }) => connection.transport !== "local_agent")
  ) {
    throw new Error(
      "Multi-agent Forge does not permit direct cloud model workers",
    );
  }
  const resolvedAgentIds = bindings
    .map(({ worker }) => agentIds.get(worker.id))
    .filter((id): id is string => Boolean(id));
  if (resolvedAgentIds.length !== bindings.length) {
    throw new Error(
      "Multi-agent Forge requires every worker to resolve to an agent",
    );
  }
  if (new Set(resolvedAgentIds).size < 2) {
    throw new Error(
      "Multi-agent Forge requires workers on at least two Agents",
    );
  }
}

function digest(value: string): string {
  return [...new Uint8Array(new TextEncoder().encode(value))]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function parseJsonArray(value: unknown): readonly string[] {
  if (typeof value !== "string") return [];
  try {
    const parsed: unknown = JSON.parse(value);
    return Array.isArray(parsed)
      ? parsed.filter((item): item is string => typeof item === "string")
      : [];
  } catch {
    return [];
  }
}

function cost(value: unknown): WorkerCostMetadata {
  const record =
    typeof value === "object" && value !== null
      ? (value as Record<string, unknown>)
      : {};
  const numberOrNull = (item: unknown): number | null =>
    typeof item === "number" ? item : null;
  return {
    currency: typeof record.currency === "string" ? record.currency : "USD",
    estimatedCostMicrosPerAttempt: numberOrNull(
      record.estimatedCostMicrosPerAttempt,
    ),
    inputMicrosPerMillionTokens: numberOrNull(
      record.inputMicrosPerMillionTokens,
    ),
    outputMicrosPerMillionTokens: numberOrNull(
      record.outputMicrosPerMillionTokens,
    ),
  };
}

function workerResource(row: Record<string, unknown>): WorkerResource {
  const workerStatus = String(row.worker_status ?? row.status ?? "offline");
  const agentStatus =
    row.revoked_at == null ? String(row.agent_status ?? "offline") : "offline";
  const enabled = row.enabled === undefined || row.enabled === 1;
  return {
    id: String(row.id),
    name: String(row.name),
    type: "agent" as WorkerType,
    capabilities: parseJsonArray(row.capabilities_json),
    roles: parseJsonArray(row.roles_json),
    permissions: parseJsonArray(row.permissions_json),
    independenceKey: String(row.independence_key),
    connectionIds: [String(row.id)],
    availability:
      enabled && agentStatus === "online" && workerStatus === "available"
        ? "available"
        : (workerStatus as WorkerAvailability),
  };
}

function connectionResource(row: Record<string, unknown>): ExecutionChannel {
  const workerStatus = String(row.worker_status ?? "offline");
  const agentStatus =
    row.revoked_at == null ? String(row.agent_status ?? "offline") : "offline";
  return {
    id: String(row.id),
    name: `${String(row.name)} Agent channel`,
    transport: "local_agent",
    provider: null,
    adapterVersion: String(row.plugin_version_policy ?? "latest"),
    authMode: "local_session",
    billingMode: String(row.billing_mode) as ExecutionChannel["billingMode"],
    cost: cost(row.cost_metadata_json),
    executionEnvironment: "local" as ExecutionEnvironment,
    availability:
      row.enabled !== 0 &&
      agentStatus === "online" &&
      workerStatus === "available"
        ? "available"
        : (workerStatus as WorkerAvailability),
  };
}

class D1WorkerRegistry implements WorkerRegistry {
  private readonly workers: readonly WorkerExecutionBinding[];

  constructor(workers: readonly WorkerExecutionBinding[]) {
    this.workers = workers;
  }

  upsert(): void {
    throw new Error("Forge worker registry is read-only during execution");
  }

  list(): readonly WorkerExecutionBinding[] {
    return this.workers;
  }

  resolve(requirement: WorkerRequirement): WorkerExecutionBinding | null {
    return (
      [...this.workers]
        .filter(
          ({ worker, connection }) =>
            worker.availability === "available" &&
            connection.availability === "available",
        )
        .filter(({ worker }) =>
          worker.capabilities.includes(requirement.capability),
        )
        .filter(
          ({ worker }) =>
            requirement.role === undefined ||
            worker.roles.includes(requirement.role),
        )
        .filter(
          ({ worker }) =>
            requirement.permission === undefined ||
            worker.permissions.includes(requirement.permission),
        )
        .filter(
          ({ connection }) =>
            requirement.executionEnvironment === undefined ||
            connection.executionEnvironment ===
              requirement.executionEnvironment,
        )
        .filter(
          ({ connection }) =>
            requirement.maxEstimatedCostMicrosPerAttempt === undefined ||
            (connection.cost.estimatedCostMicrosPerAttempt !== null &&
              connection.cost.estimatedCostMicrosPerAttempt <=
                requirement.maxEstimatedCostMicrosPerAttempt),
        )
        .sort(
          (left, right) =>
            (left.connection.cost.estimatedCostMicrosPerAttempt ??
              Number.MAX_SAFE_INTEGER) -
              (right.connection.cost.estimatedCostMicrosPerAttempt ??
                Number.MAX_SAFE_INTEGER) ||
            left.worker.id.localeCompare(right.worker.id) ||
            left.connection.id.localeCompare(right.connection.id),
        )[0] ?? null
    );
  }
}

class DurableForgePersistence implements ForgePersistence {
  private readonly artifacts: ThresholdArtifactStore;

  constructor(
    private readonly repositories: D1PersistenceRepositories,
    private readonly r2: R2ArtifactStore,
  ) {
    this.artifacts = new ThresholdArtifactStore(64 * 1024, this.r2);
  }

  saveGoal(goal: GoalRecord): Promise<void> {
    return this.repositories.goals.save(goal);
  }

  saveRun(run: RunRecord): Promise<void> {
    return this.repositories.runs.save(run);
  }

  savePhase(
    phase: Parameters<ForgePersistence["savePhase"]>[0],
  ): Promise<void> {
    return this.repositories.phases.save(phase);
  }

  saveTask(task: Parameters<ForgePersistence["saveTask"]>[0]): Promise<void> {
    return this.repositories.tasks.save(task);
  }

  saveTaskDependency(
    dependency: Parameters<ForgePersistence["saveTaskDependency"]>[0],
  ): Promise<void> {
    return this.repositories.taskDependencies.save(dependency);
  }

  saveAttempt(
    attempt: Parameters<ForgePersistence["saveAttempt"]>[0],
  ): Promise<void> {
    return this.repositories.attempts.save(attempt);
  }

  saveModelCall(
    call: Parameters<ForgePersistence["saveModelCall"]>[0],
  ): Promise<void> {
    return this.repositories.modelCalls.save(call);
  }

  saveFinding(
    finding: Parameters<ForgePersistence["saveFinding"]>[0],
  ): Promise<void> {
    return this.repositories.findings.save(finding);
  }

  saveVerification(
    verification: Parameters<ForgePersistence["saveVerification"]>[0],
  ): Promise<void> {
    return this.repositories.verifications.save(verification);
  }

  async saveArtifact(artifact: ArtifactRecord): Promise<void> {
    const persisted =
      artifact.payload.kind === "inline"
        ? await this.artifacts.persist(
            {
              id: artifact.id,
              runId: artifact.runId,
              taskId: artifact.taskId,
              attemptId: artifact.attemptId,
              mediaType: artifact.mediaType,
              contentDigest: artifact.contentDigest,
              provenance: artifact.provenance,
              createdAt: artifact.createdAt,
            },
            artifact.payload.content,
          )
        : artifact;
    await this.repositories.artifacts.save(persisted);
  }

  appendEvent(
    event: Parameters<ForgePersistence["appendEvent"]>[0],
  ): Promise<void> {
    return this.repositories.events.append(event);
  }

  async resolve(artifactId: string) {
    const artifact = await this.repositories.artifacts.get(artifactId);
    if (!artifact) return null;
    if (artifact.payload.kind === "inline") {
      return {
        artifactId: artifact.id,
        mediaType: artifact.mediaType,
        content: artifact.payload.content,
      };
    }
    const bytes = await this.r2.get(artifact.payload);
    return bytes
      ? {
          artifactId: artifact.id,
          mediaType: artifact.mediaType,
          content: new TextDecoder().decode(bytes),
        }
      : null;
  }
}

/**
 * Executes repository operations through an Agent Worker assignment.
 *
 * Cloud owns orchestration and evidence persistence, while the Agent/Plugin
 * owns filesystem and process access. Keeping this adapter on the Worker
 * execution interface prevents Forge from growing a second host transport.
 */
class AgentWorkerRuntime implements ForgeRuntimeAdapter {
  constructor(
    private readonly env: ForgeExecutionEnv,
    private readonly context: ForgeExecutionContext,
    private readonly worker: WorkerExecutor,
  ) {}

  inspect(input: Parameters<ForgeRuntimeAdapter["inspect"]>[0]) {
    return this.execute(
      "search",
      { query: input.objective, path: "." },
      input.taskId,
      input.repositoryId,
      input.revision,
    );
  }

  async apply(
    input: Parameters<ForgeRuntimeAdapter["apply"]>[0],
  ): Promise<ForgeRuntimeEvidence> {
    const evidence: ForgeRuntimeEvidence[] = [];
    for (const operation of input.operations) {
      const result = await this.executeOperation(
        operation,
        input.taskId,
        input.repositoryId,
        input.revision,
      );
      evidence.push(result);
      if (result.status !== "succeeded") break;
    }
    const failed = evidence.find((item) => item.status !== "succeeded");
    const applied: ForgeRuntimeEvidence = {
      operation: "apply",
      status: failed ? "failed" : "succeeded",
      summary: failed?.summary ?? "apply completed",
      content: evidence.map((item) => item.content).join("\n"),
      contentDigest: digest(
        evidence.map((item) => item.contentDigest).join(":"),
      ),
      ...(failed?.command ? { command: failed.command } : {}),
      ...(failed ? { exitCode: failed.exitCode } : {}),
    };
    return applied;
  }

  async test(input: Parameters<ForgeRuntimeAdapter["test"]>[0]) {
    const command = this.command();
    return this.execute(
      "test",
      {
        command,
        cwd: ".",
        changedFiles: input.changedFiles,
      },
      input.taskId,
      input.repositoryId,
      input.revision,
    );
  }

  private async executeOperation(
    operation: ImplementationOperation,
    taskId: string,
    repositoryId: string,
    revision: string,
  ): Promise<ForgeRuntimeEvidence> {
    const { kind, ...details } = operation;
    return this.execute(kind, details, taskId, repositoryId, revision);
  }

  private async execute(
    kind: "search" | "write_file" | "patch_file" | "delete_file" | "test",
    details: Record<string, unknown>,
    taskId = this.context.taskId,
    repositoryId = this.context.repositoryId,
    revision = this.context.revision,
  ): Promise<ForgeRuntimeEvidence> {
    const operationPayload = parseRuntimeOperationRequest({
      protocol: "conclave.protocol",
      version: "0.1",
      messageId: crypto.randomUUID(),
      goalId: this.context.goalId,
      runId: this.context.runId,
      workerId: this.worker.resource.id,
      createdAt: new Date().toISOString(),
      messageType: "RuntimeOperationRequest",
      payload: {
        operation: kind,
        taskId,
        repositoryId,
        revision,
        ...details,
      },
    }).payload;
    const result = await this.worker.execute({
      requestId: crypto.randomUUID(),
      goalId: this.context.goalId,
      runId: this.context.runId,
      taskId,
      attemptId: `${this.context.executionId}:${taskId}:${kind}`,
      workerId: this.worker.resource.id,
      connectionId: this.worker.connection.id,
      repositoryId,
      message: {
        protocol: "conclave.protocol",
        version: "0.1",
        messageType: "RuntimeOperationRequest",
        payload: operationPayload,
      },
      context: [],
      deadlineAt: new Date(Date.now() + 15 * 60_000).toISOString(),
    });
    const output = this.parseOutput(result.output);
    const content =
      typeof output.content === "string"
        ? output.content
        : (result.output ?? result.error?.message ?? "");
    const checks = this.parseChecks(output.checks) ?? [];
    return {
      operation:
        kind === "test" ? "test" : kind === "search" ? "research" : "apply",
      status: result.status === "succeeded" ? "succeeded" : "failed",
      summary:
        typeof output.summary === "string"
          ? output.summary
          : result.status === "succeeded"
            ? `${kind} completed`
            : (result.error?.message ?? `${kind} failed`),
      content,
      contentDigest: digest(content),
      ...(Array.isArray(output.command)
        ? {
            command: output.command.filter(
              (item): item is string => typeof item === "string",
            ),
          }
        : {}),
      ...(typeof output.exitCode === "number"
        ? { exitCode: output.exitCode }
        : {}),
      ...(checks.length > 0 ? { checks } : {}),
    };
  }

  private parseOutput(value: string | null): Record<string, unknown> {
    if (!value) return {};
    try {
      const parsed: unknown = JSON.parse(value);
      return typeof parsed === "object" && parsed !== null
        ? (parsed as Record<string, unknown>)
        : { content: value };
    } catch {
      return { content: value };
    }
  }

  private parseChecks(value: unknown): ForgeRuntimeEvidence["checks"] {
    if (!Array.isArray(value)) return [];
    return value.flatMap((item) => {
      if (typeof item !== "object" || item === null) return [];
      const check = item as Record<string, unknown>;
      const name = typeof check.name === "string" ? check.name : null;
      const status = check.status;
      if (
        !name ||
        (status !== "passed" &&
          status !== "failed" &&
          status !== "skipped" &&
          status !== "inconclusive")
      ) {
        return [];
      }
      return [
        {
          name,
          status,
          ...(typeof check.command === "string"
            ? { command: check.command }
            : {}),
          ...(typeof check.exitCode === "number"
            ? { exitCode: check.exitCode }
            : {}),
        },
      ];
    });
  }

  private command(): readonly string[] {
    if (!this.env.CONCLAVE_TEST_COMMAND) return ["pnpm", "check"];
    const parsed: unknown = JSON.parse(this.env.CONCLAVE_TEST_COMMAND);
    if (
      !Array.isArray(parsed) ||
      parsed.some((item) => typeof item !== "string")
    ) {
      throw new Error("CONCLAVE_TEST_COMMAND must be a JSON string array");
    }
    return parsed;
  }
}

class AgentGatewayWorkerExecutor implements WorkerExecutor {
  constructor(
    readonly resource: WorkerResource,
    readonly connection: ExecutionChannel,
    private readonly env: ForgeExecutionEnv,
    private readonly context: ForgeExecutionContext,
  ) {}

  async execute(
    request: WorkerExecutionRequest,
  ): Promise<WorkerExecutionResult> {
    const message =
      typeof request.message === "object" && request.message !== null
        ? (request.message as Record<string, unknown>)
        : {};
    const payload =
      typeof message.payload === "object" && message.payload !== null
        ? (message.payload as Record<string, unknown>)
        : {};
    const objective =
      typeof payload.objective === "string"
        ? payload.objective
        : `Execute ${String(message.messageType ?? "worker task")}`;
    const role =
      typeof payload.role === "string"
        ? payload.role
        : (this.resource.roles[0] ?? "worker");
    const capabilities = Array.isArray(payload.requiredCapabilities)
      ? payload.requiredCapabilities.filter(
          (value): value is string => typeof value === "string",
        )
      : this.resource.capabilities;
    const task = {
      id: request.taskId,
      role,
      objective,
      capabilities,
      contextArtifactIds: request.context.map((item) => item.artifactId),
      timeoutMs: this.deadline(request),
      repository: {
        repositoryId: request.repositoryId,
        revision: this.revisionFromMessage(message),
      },
      input: {
        request,
        message: request.message,
        context: request.context,
      },
    };
    const dispatched = await this.dispatch(request, task);
    if (!dispatched.accepted) {
      return this.failed(dispatched.error ?? "Agent assignment was rejected");
    }

    const deadline = Date.now() + this.deadline(request);
    while (Date.now() < deadline) {
      const row = await this.env.CONCLAVE_DB.prepare(
        `SELECT status, output_json, error_json
         FROM worker_assignments WHERE id = ?1`,
      )
        .bind(dispatched.assignmentId)
        .first<{
          status: string;
          output_json: string | null;
          error_json: string | null;
        }>();
      if (row?.status === "completed" && row.output_json) {
        const result = JSON.parse(row.output_json) as {
          output?: unknown;
          artifactIds?: unknown;
          summary?: unknown;
        };
        const output =
          typeof result.output === "string"
            ? result.output
            : JSON.stringify(result.output ?? { summary: result.summary });
        return {
          status: "succeeded",
          output,
          rawOutput: output,
          executionId: dispatched.assignmentId,
          usage: { inputTokens: null, outputTokens: null },
          evidenceArtifactIds: Array.isArray(result.artifactIds)
            ? result.artifactIds.filter(
                (value): value is string => typeof value === "string",
              )
            : [],
        };
      }
      if (row?.status === "failed" || row?.status === "cancelled") {
        return this.failed(
          this.assignmentError(row.error_json) ??
            `Agent assignment ended with status ${row.status}`,
        );
      }
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
    return this.failed("Timed out waiting for Agent assignment result", true);
  }

  private async dispatch(
    request: WorkerExecutionRequest,
    task: {
      id: string;
      role: string;
      objective: string;
      capabilities: readonly string[];
      contextArtifactIds: readonly string[];
      timeoutMs: number;
      input: Record<string, unknown>;
    },
  ): Promise<DispatchAssignmentResult> {
    const dispatcherEnv = this.env as unknown as AssignmentDispatcherEnv;
    if (this.env.CONCLAVE_AGENT_GATEWAY) {
      return dispatchTaskAssignment(dispatcherEnv, {
        workspaceId: this.context.organizationId,
        runId: request.runId,
        taskId: request.taskId,
        explicitWorkerId: this.resource.id,
        task,
      });
    }

    const token = this.env.CONCLAVE_FORGE_CALLBACK_TOKEN;
    if ((!this.env.CONCLAVE_API && !this.env.CONCLAVE_API_BASE_URL) || !token) {
      return {
        assignmentId: "",
        attemptId: "",
        workerId: this.resource.id,
        agentId: "",
        pluginId: this.resource.id,
        status: "failed",
        accepted: false,
        error: "Agent Gateway or internal Forge dispatch is not configured",
      };
    }
    const dispatchRequest = new Request(
      this.env.CONCLAVE_API
        ? "https://conclave.internal/api/internal/agent-assignments/dispatch"
        : `${this.env.CONCLAVE_API_BASE_URL!.replace(/\/$/, "")}/api/internal/agent-assignments/dispatch`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          workspaceId: this.context.organizationId,
          runId: request.runId,
          taskId: request.taskId,
          workerId: this.resource.id,
          task,
        }),
      },
    );
    const response = await (this.env.CONCLAVE_API
      ? this.env.CONCLAVE_API.fetch(dispatchRequest)
      : fetch(dispatchRequest));
    const body = (await response.json()) as {
      assignment?: DispatchAssignmentResult;
      error?: string;
    };
    if (!response.ok || !body.assignment) {
      return {
        assignmentId: "",
        attemptId: "",
        workerId: this.resource.id,
        agentId: "",
        pluginId: this.resource.id,
        status: "failed",
        accepted: false,
        error:
          body.error ?? `Internal Forge dispatch failed (${response.status})`,
      };
    }
    return body.assignment;
  }

  private deadline(request: WorkerExecutionRequest): number {
    if (!request.deadlineAt) return 15 * 60_000;
    return Math.max(1000, new Date(request.deadlineAt).getTime() - Date.now());
  }

  private revisionFromMessage(message: Record<string, unknown>): string {
    const payload =
      typeof message.payload === "object" && message.payload !== null
        ? (message.payload as Record<string, unknown>)
        : {};
    return typeof payload.revision === "string" && payload.revision.length > 0
      ? payload.revision
      : "HEAD";
  }

  private failed(message: string, retryable = false): WorkerExecutionResult {
    return {
      status: "failed",
      output: null,
      rawOutput: null,
      usage: { inputTokens: null, outputTokens: null },
      evidenceArtifactIds: [],
      error: { code: "agent_assignment_failed", message, retryable },
    };
  }

  private assignmentError(value: string | null): string | null {
    if (!value) return null;
    try {
      const parsed = JSON.parse(value) as { error?: { message?: unknown } };
      return typeof parsed.error?.message === "string"
        ? parsed.error.message
        : null;
    } catch {
      return null;
    }
  }
}

async function discoverLocalWorkers(
  env: ForgeExecutionEnv,
): Promise<ReadonlySet<string>> {
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT w.id
     FROM workers w JOIN agents a ON a.id = w.agent_id
     WHERE w.enabled = 1 AND w.status = 'available'
       AND a.status = 'online' AND a.revoked_at IS NULL`,
  ).all<{ id: string }>();
  return new Set((rows.results ?? []).map((row) => row.id));
}

function modelFor(
  binding: WorkerExecutionBinding,
  env: ForgeExecutionEnv,
  context: ForgeExecutionContext,
): WorkerExecutor {
  const { worker: resource, connection } = binding;
  if (connection.transport === "local_agent") {
    return new AgentGatewayWorkerExecutor(resource, connection, env, context);
  }
  throw new Error(
    `Forge requires Dart Agent execution; unsupported transport: ${connection.transport}`,
  );
}

export type ForgeExecutionMode = "single_agent" | "multi_agent";

export function resolveForgeExecutionMode(value: unknown): ForgeExecutionMode {
  if (value === "cloud_api") {
    throw new Error(
      "Forge direct cloud model execution has been retired; use Dart Agent workers",
    );
  }
  return value === "multi_agent" ? "multi_agent" : "single_agent";
}

export async function readExecutionContext(
  env: ForgeExecutionEnv,
  params: Record<string, unknown>,
  executionId: string,
): Promise<ForgeExecutionContext> {
  const runId = String(params.runId ?? "");
  const goalId = String(params.goalId ?? "");
  const organizationId = String(params.organizationId ?? "");
  if (!runId || !goalId || !organizationId) {
    throw new Error(
      "Forge execution requires runId, goalId, and organizationId",
    );
  }
  const project = await env.CONCLAVE_DB.prepare(
    `SELECT p.id AS project_id, p.repository_id,
            g.id AS goal_id, r.goal_id AS run_goal_id,
            r.project_id AS run_project_id
     FROM projects p
     JOIN goals g ON g.project_id = p.id
     LEFT JOIN runs r ON r.id = ?2
     WHERE g.id = ?1 AND p.workspace_id = ?3`,
  )
    .bind(goalId, runId, organizationId)
    .first<{
      project_id: string;
      repository_id: string | null;
      goal_id: string;
      run_goal_id: string | null;
      run_project_id: string | null;
    }>();
  if (!project)
    throw new Error("Goal is not owned by the execution organization");
  if (project.run_goal_id && project.run_goal_id !== goalId) {
    throw new Error("Run does not belong to the requested Goal");
  }
  if (project.run_project_id && project.run_project_id !== project.project_id) {
    throw new Error("Run does not belong to the requested Project");
  }
  if (
    typeof params.projectId === "string" &&
    params.projectId.length > 0 &&
    params.projectId !== project.project_id
  ) {
    throw new Error("Forge project does not match the Goal project");
  }
  if (
    typeof params.repositoryId === "string" &&
    params.repositoryId.length > 0 &&
    params.repositoryId !== project.repository_id
  ) {
    throw new Error("Forge repository does not match the Project repository");
  }
  return {
    executionId,
    runId,
    taskId: String(params.taskId ?? `${runId}:runtime`),
    goalId,
    organizationId,
    projectId: String(params.projectId ?? project.project_id),
    repositoryId: String(params.repositoryId ?? project.repository_id ?? ""),
    revision: String(params.revision ?? "HEAD"),
  };
}

export async function executeForgeService(
  env: ForgeExecutionEnv,
  params: Record<string, unknown>,
  executionId: string,
): Promise<string> {
  const context = await readExecutionContext(env, params, executionId);
  if (!context.repositoryId)
    throw new Error("Forge repository is not configured");
  const repositories = new D1PersistenceRepositories(env.CONCLAVE_DB);
  const goal = await repositories.goals.get(context.goalId);
  if (!goal) throw new Error("Goal was not found");
  const existingRun = await repositories.runs.get(context.runId);
  const now = new Date().toISOString();
  const run: RunRecord = existingRun ?? {
    id: context.runId,
    goalId: context.goalId,
    workflowInstanceId: null,
    parentRunId: null,
    policySnapshot: {},
    currentPhaseId: null,
    status: "running",
    startedAt: now,
    finishedAt: null,
    createdAt: now,
    updatedAt: now,
  };
  const workers = await env.CONCLAVE_DB.prepare(
    `SELECT
       w.id, w.agent_id, w.name, w.plugin_id, w.plugin_version_policy,
       w.roles_json, w.capabilities_json, w.secret_refs_json,
       w.independence_key, w.billing_mode, w.cost_metadata_json,
       w.status AS worker_status, w.enabled,
       a.status AS agent_status, a.revoked_at
     FROM workers w
     JOIN agents a ON a.id = w.agent_id
     WHERE w.workspace_id = ?1
     ORDER BY w.id`,
  )
    .bind(context.organizationId)
    .all<Record<string, unknown>>();
  const registry: WorkerRegistry = new D1WorkerRegistry(
    (workers.results ?? []).map((row) => ({
      worker: workerResource(row),
      connection: connectionResource(row),
    })),
  );
  const leadResource =
    registry.resolve({ capability: "planning" }) ??
    registry.resolve({ capability: "repository_read" });
  const implementerResource = registry.resolve({
    capability: "repository_write",
  });
  const reviewerResource = registry.resolve({ capability: "code_review" });
  const runtimeResource = registry.resolve({
    capability: "repository_read",
    executionEnvironment: "local",
  });
  if (
    !leadResource ||
    !implementerResource ||
    !reviewerResource ||
    !runtimeResource
  ) {
    throw new Error(
      "Forge requires planning, implementation, review, and runtime workers",
    );
  }
  if (reviewerResource.worker.id === implementerResource.worker.id) {
    throw new Error("Forge requires independent worker resources");
  }
  const executionMode = resolveForgeExecutionMode(params.executionMode);
  const agentIds = new Map(
    (workers.results ?? []).map((row) => [
      String(row.id),
      String(row.agent_id),
    ]),
  );
  const selectedBindings = [
    leadResource,
    implementerResource,
    reviewerResource,
  ];
  if (executionMode === "single_agent") {
    assertSingleAgentForgeBindings(selectedBindings, agentIds);
  }
  if (executionMode === "multi_agent") {
    assertMultiAgentForgeBindings(selectedBindings, agentIds);
  }
  const secondaryResearchResource =
    executionMode === "multi_agent"
      ? registry
          .list()
          .find(
            ({ worker, connection }) =>
              connection.transport === "local_agent" &&
              worker.capabilities.includes("repository_read") &&
              agentIds.get(worker.id) !== agentIds.get(leadResource.worker.id),
          )
      : undefined;
  if (executionMode === "multi_agent" && !secondaryResearchResource) {
    throw new Error(
      "Multi-agent Forge requires a repository research worker on the second Agent",
    );
  }
  const localBindings = [
    leadResource,
    implementerResource,
    reviewerResource,
    runtimeResource,
  ].filter((binding) => binding.connection.transport === "local_agent");
  const discoveredLocalWorkers =
    localBindings.length > 0
      ? await discoverLocalWorkers(env)
      : new Set<string>();
  for (const binding of localBindings) {
    if (!discoveredLocalWorkers.has(binding.worker.id)) {
      throw new Error(`Local Worker ${binding.worker.id} is not connected`);
    }
  }
  const persistence = new DurableForgePersistence(
    repositories,
    new R2ArtifactStore(
      env.CONCLAVE_ARTIFACTS,
      env.CONCLAVE_ARTIFACT_BUCKET_NAME ?? "conclave-artifacts-development",
    ),
  );
  try {
    const result = await executeForgeGoal({
      goal,
      run,
      repositoryId: context.repositoryId,
      revision: context.revision,
      lead: modelFor(leadResource, env, context),
      implementer: modelFor(implementerResource, env, context),
      reviewer: modelFor(reviewerResource, env, context),
      ...(secondaryResearchResource
        ? {
            secondaryResearcher: modelFor(
              secondaryResearchResource,
              env,
              context,
            ),
          }
        : {}),
      requireSecondaryResearch: executionMode === "multi_agent",
      runtime: new AgentWorkerRuntime(
        env,
        context,
        new AgentGatewayWorkerExecutor(
          runtimeResource.worker,
          runtimeResource.connection,
          env,
          context,
        ),
      ),
      persistence,
    });
    await repositories.runs.save({
      ...run,
      status: "completed",
      finishedAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    });
    await repositories.goals.save({
      ...goal,
      status: "completed",
      updatedAt: new Date().toISOString(),
    });
    return result.completion.payload.finalReportArtifactId;
  } catch (error) {
    await repositories.runs.save({
      ...run,
      status: "failed",
      finishedAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    });
    throw error;
  }
}

export class ConclaveForgeExecutionService {
  constructor(private readonly env: ForgeExecutionEnv) {}

  async fetch(request: Request, ctx: ExecutionContext): Promise<Response> {
    const pathname = new URL(request.url).pathname;
    const statusMatch = pathname.match(/^\/status\/([^/]+)$/);
    if (request.method === "GET" && statusMatch?.[1]) {
      const row = await this.env.CONCLAVE_DB.prepare(
        "SELECT execution_id, run_id, status, result_artifact_id, error, updated_at FROM forge_executions WHERE execution_id = ?1",
      )
        .bind(statusMatch[1])
        .first<Record<string, unknown>>();
      if (!row)
        return Response.json({ error: "execution_not_found" }, { status: 404 });
      return Response.json(forgeExecutionRecord(row));
    }
    if (request.method !== "POST" || pathname !== "/execute") {
      return Response.json({ error: "not_found" }, { status: 404 });
    }
    const params = (await request.json()) as Record<string, unknown>;
    if (typeof params.runId !== "string" || params.runId.length === 0) {
      return Response.json({ error: "run_id_required" }, { status: 400 });
    }
    const requestedWorkspaceId =
      typeof params.organizationId === "string" ? params.organizationId : null;
    const responseForExecution = (row: Record<string, unknown>): Response => {
      if (
        requestedWorkspaceId &&
        row.workspace_id &&
        String(row.workspace_id) !== requestedWorkspaceId
      ) {
        return Response.json(
          { error: "run_workspace_mismatch" },
          { status: 409 },
        );
      }
      const persisted = forgeExecutionRecord(row);
      return Response.json(
        {
          executionId: persisted.executionId,
          runId: persisted.runId,
          status: persisted.status,
          ...(persisted.resultArtifactId
            ? { resultArtifactId: persisted.resultArtifactId }
            : {}),
          ...(persisted.error ? { error: persisted.error } : {}),
        },
        { status: persisted.status === "started" ? 202 : 200 },
      );
    };
    const existing = await this.env.CONCLAVE_DB.prepare(
      `SELECT execution_id, run_id, workspace_id, status, result_artifact_id, error, updated_at
       FROM forge_executions WHERE run_id = ?1`,
    )
      .bind(params.runId)
      .first<Record<string, unknown>>();
    if (existing) {
      return responseForExecution(existing);
    }
    const executionId = crypto.randomUUID();
    const runId = params.runId;
    const now = new Date().toISOString();
    const record: ForgeExecutionRecord = {
      executionId,
      runId,
      status: "started",
      updatedAt: now,
    };
    await this.env.CONCLAVE_DB.prepare(
      `INSERT INTO forge_executions
       (execution_id, run_id, workspace_id, status, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?5)
       ON CONFLICT(run_id) DO NOTHING`,
    )
      .bind(
        executionId,
        runId,
        typeof params.organizationId === "string"
          ? params.organizationId
          : null,
        record.status,
        now,
      )
      .run();
    const persisted = await this.env.CONCLAVE_DB.prepare(
      `SELECT execution_id, run_id, workspace_id, status, result_artifact_id, error, updated_at
       FROM forge_executions WHERE run_id = ?1`,
    )
      .bind(runId)
      .first<Record<string, unknown>>();
    if (!persisted) {
      return Response.json(
        { error: "forge_execution_persistence_failed" },
        { status: 500 },
      );
    }
    if (String(persisted.execution_id) !== executionId) {
      return responseForExecution(persisted);
    }
    ctx.waitUntil(this.runAndNotify(params, executionId));
    return Response.json({ executionId }, { status: 202 });
  }

  private async updateExecution(
    executionId: string,
    patch: Omit<Partial<ForgeExecutionRecord>, "executionId" | "runId">,
  ): Promise<void> {
    const row = await this.env.CONCLAVE_DB.prepare(
      "SELECT execution_id, run_id, status, result_artifact_id, error, updated_at FROM forge_executions WHERE execution_id = ?1",
    )
      .bind(executionId)
      .first<Record<string, unknown>>();
    if (!row) return;
    const existing = forgeExecutionRecord(row);
    const updated: ForgeExecutionRecord = {
      ...existing,
      ...patch,
      executionId,
      updatedAt: new Date().toISOString(),
    };
    await this.env.CONCLAVE_DB.prepare(
      `UPDATE forge_executions
       SET status = ?1, result_artifact_id = ?2, error = ?3, updated_at = ?4
       WHERE execution_id = ?5`,
    )
      .bind(
        updated.status,
        updated.resultArtifactId ?? null,
        updated.error ?? null,
        updated.updatedAt,
        executionId,
      )
      .run();
  }

  private async runAndNotify(
    params: Record<string, unknown>,
    executionId: string,
  ): Promise<void> {
    const runId = String(params.runId ?? "");
    let resultArtifactId: string;
    try {
      if (
        !this.env.CONCLAVE_API &&
        !this.env.CONCLAVE_API_BASE_URL &&
        !this.env.CONCLAVE_AGENT_GATEWAY
      ) {
        throw new Error(
          "CONCLAVE_AGENT_GATEWAY, CONCLAVE_API, or CONCLAVE_API_BASE_URL is not configured",
        );
      }
      resultArtifactId = await executeForgeService(
        this.env,
        params,
        executionId,
      );
    } catch (error) {
      await this.updateExecution(executionId, {
        status: "failed",
        error:
          error instanceof Error ? error.message : "Forge execution failed",
      });
      await this.notifyBestEffort(runId, {
        eventId: crypto.randomUUID(),
        runId,
        executionId,
        status: "failed",
        error:
          error instanceof Error ? error.message : "Forge execution failed",
      });
      return;
    }

    // Persist the terminal Forge result before notifying the Workflow. A
    // callback outage must not rewrite a real completion as a Forge failure.
    await this.updateExecution(executionId, {
      status: "completed",
      resultArtifactId,
    });
    await this.notifyBestEffort(runId, {
      eventId: crypto.randomUUID(),
      runId,
      executionId,
      status: "completed",
      resultArtifactId,
    });
  }

  private async notifyBestEffort(
    runId: string,
    payload: Record<string, unknown>,
  ): Promise<void> {
    try {
      await this.notify(runId, payload);
    } catch {
      // The D1 execution record is authoritative and can be reconciled after
      // a callback outage or service restart.
    }
  }

  private async notify(
    runId: string,
    payload: Record<string, unknown>,
  ): Promise<void> {
    const callbackRequest = new Request(
      this.env.CONCLAVE_API
        ? `https://conclave.internal/api/runs/${encodeURIComponent(runId)}/forge-events`
        : `${this.env.CONCLAVE_API_BASE_URL!.replace(/\/$/, "")}/api/runs/${encodeURIComponent(runId)}/forge-events`,
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          ...(this.env.CONCLAVE_FORGE_CALLBACK_TOKEN
            ? {
                authorization: `Bearer ${this.env.CONCLAVE_FORGE_CALLBACK_TOKEN}`,
              }
            : {}),
        },
        body: JSON.stringify(payload),
      },
    );
    const response = await (this.env.CONCLAVE_API
      ? this.env.CONCLAVE_API.fetch(callbackRequest)
      : fetch(callbackRequest));
    if (!response.ok)
      throw new Error(`Forge callback failed with ${response.status}`);
  }
}

export default {
  fetch(request: Request, env: ForgeExecutionEnv, ctx: ExecutionContext) {
    return new ConclaveForgeExecutionService(env).fetch(request, ctx);
  },
};
