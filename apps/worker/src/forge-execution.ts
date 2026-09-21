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
  WorkerBinding,
  ConnectionResource,
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
  AnthropicMessagesWorker,
  OpenAIResponsesWorker,
} from "@conclave/providers";
import type { ImplementationOperation } from "@conclave/protocol";
import type {
  RuntimeEvidence,
  RuntimeOperation,
} from "@conclave/local-runtime";
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
  readonly CONCLAVE_FORGE_CALLBACK_TOKEN?: string;
  readonly CONCLAVE_OPENAI_API_KEY?: string;
  readonly CONCLAVE_ANTHROPIC_API_KEY?: string;
  readonly CONCLAVE_WORKER_MODELS?: string;
  readonly CONCLAVE_LOCAL_RUNTIME_URL?: string;
  readonly CONCLAVE_LOCAL_RUNTIME_TOKEN?: string;
  readonly CONCLAVE_RUNTIME_ID?: string;
  readonly CONCLAVE_RUNTIME_OPERATION_TOKEN?: string;
  readonly CONCLAVE_TEST_COMMAND?: string;
  readonly CONCLAVE_RUNTIME_APPROVAL_ID?: string;
  readonly CONCLAVE_RUNTIME_APPROVAL_EXPIRES_AT?: string;
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

export function assertSingleAgentForgeBindings(
  bindings: readonly WorkerBinding[],
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
  bindings: readonly WorkerBinding[],
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
  return {
    id: String(row.id),
    name: String(row.name),
    type: String(row.kind) as WorkerType,
    capabilities: parseJsonArray(row.capabilities_json),
    roles: parseJsonArray(row.roles_json),
    permissions: parseJsonArray(row.permissions_json),
    independenceKey: String(row.independence_key),
    connectionIds: [String(row.connection_id)],
    availability: String(row.availability) as WorkerAvailability,
  };
}

function connectionResource(row: Record<string, unknown>): ConnectionResource {
  return {
    id: String(row.connection_id),
    name: String(row.connection_name),
    transport: String(row.transport) as ConnectionResource["transport"],
    provider: typeof row.provider === "string" ? row.provider : null,
    adapterVersion: String(row.connection_adapter_version),
    authMode: String(row.auth_mode) as ConnectionResource["authMode"],
    billingMode: String(row.billing_mode) as ConnectionResource["billingMode"],
    cost: cost(row.cost_metadata_json),
    executionEnvironment: String(
      row.execution_environment,
    ) as ExecutionEnvironment,
    availability: String(row.connection_availability) as WorkerAvailability,
  };
}

class D1WorkerRegistry implements WorkerRegistry {
  private readonly workers: readonly WorkerBinding[];

  constructor(workers: readonly WorkerBinding[]) {
    this.workers = workers;
  }

  upsert(): void {
    throw new Error("Forge worker registry is read-only during execution");
  }

  list(): readonly WorkerBinding[] {
    return this.workers;
  }

  resolve(requirement: WorkerRequirement): WorkerBinding | null {
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

class RemoteLocalRuntime implements ForgeRuntimeAdapter {
  constructor(
    private readonly env: ForgeExecutionEnv,
    private readonly context: ForgeExecutionContext,
  ) {}

  inspect(input: Parameters<ForgeRuntimeAdapter["inspect"]>[0]) {
    return this.execute(
      "search",
      { query: input.objective, path: "." },
      input.taskId,
    ).then((result) =>
      this.asForgeEvidence(
        "research",
        [result],
        result.status === "succeeded" ? undefined : result,
      ),
    );
  }

  async apply(input: Parameters<ForgeRuntimeAdapter["apply"]>[0]) {
    const evidence: RuntimeEvidence[] = [];
    for (const operation of input.operations) {
      const result = await this.executeOperation(operation, input.taskId);
      evidence.push(result);
      if (result.status !== "succeeded") break;
    }
    const failed = evidence.find((item) => item.status !== "succeeded");
    return this.asForgeEvidence("apply", evidence, failed);
  }

  async test(input: Parameters<ForgeRuntimeAdapter["test"]>[0]) {
    const command = this.command();
    const result = await this.execute(
      "check",
      {
        command,
        cwd: ".",
      },
      input.taskId,
    );
    return this.asForgeEvidence(
      "test",
      [result],
      result.status === "succeeded" ? undefined : result,
    );
  }

  private async executeOperation(
    operation: ImplementationOperation,
    taskId: string,
  ) {
    if (operation.kind === "write_file") {
      return this.execute("write_file", operation, taskId);
    }
    if (operation.kind === "patch_file") {
      return this.execute("patch_file", operation, taskId);
    }
    return this.execute("delete_file", operation, taskId);
  }

  private async execute(
    kind: RuntimeOperation["kind"],
    details: Record<string, unknown>,
    taskId = this.context.taskId,
  ): Promise<RuntimeEvidence> {
    const base = {
      requestId: crypto.randomUUID(),
      organizationId: this.context.organizationId,
      projectId: this.context.projectId,
      runId: this.context.runId,
      taskId,
      repositoryId: this.context.repositoryId,
      approval: {
        approvalId:
          this.env.CONCLAVE_RUNTIME_APPROVAL_ID ??
          `${this.context.runId}:${this.context.executionId}`,
        organizationId: this.context.organizationId,
        projectId: this.context.projectId,
        runId: this.context.runId,
        taskId,
        operationKinds: [kind],
        expiresAt:
          this.env.CONCLAVE_RUNTIME_APPROVAL_EXPIRES_AT ??
          new Date(Date.now() + 60 * 60 * 1000).toISOString(),
      },
      kind,
      ...details,
    } as unknown as RuntimeOperation;
    const baseUrl = this.env.CONCLAVE_LOCAL_RUNTIME_URL;
    if (!baseUrl) throw new Error("Local Runtime URL is not configured");
    if (!this.env.CONCLAVE_RUNTIME_ID) {
      throw new Error("CONCLAVE_RUNTIME_ID is not configured");
    }
    const response = await fetch(
      `${baseUrl.replace(/\/$/, "")}/api/runtime/operations`,
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          ...(this.env.CONCLAVE_RUNTIME_ID
            ? { "x-conclave-runtime-id": this.env.CONCLAVE_RUNTIME_ID }
            : {}),
          ...(this.env.CONCLAVE_LOCAL_RUNTIME_TOKEN
            ? {
                authorization: `Bearer ${this.env.CONCLAVE_LOCAL_RUNTIME_TOKEN}`,
              }
            : {}),
        },
        body: JSON.stringify(base),
      },
    );
    const body: unknown = await response.json();
    if (!response.ok)
      throw new Error(`Local Runtime failed with ${response.status}`);
    if (typeof body !== "object" || body === null) {
      throw new Error("Local Runtime returned an invalid evidence payload");
    }
    return body as RuntimeEvidence;
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

  private asForgeEvidence(
    operation: ForgeRuntimeEvidence["operation"],
    evidence: readonly RuntimeEvidence[],
    failed: RuntimeEvidence | undefined,
  ): ForgeRuntimeEvidence {
    return {
      operation,
      status: failed ? "failed" : "succeeded",
      summary: failed?.summary ?? `${operation} completed`,
      content: evidence.map((item) => item.content).join("\n"),
      contentDigest: digest(
        evidence.map((item) => item.contentDigest).join(":"),
      ),
      ...(failed?.command ? { command: failed.command } : {}),
      ...(failed ? { exitCode: failed.exitCode } : {}),
      ...(operation === "test"
        ? {
            checks: evidence.map((item) => ({
              name: item.summary,
              status:
                item.status === "succeeded"
                  ? ("passed" as const)
                  : ("failed" as const),
              command: item.command?.join(" "),
              exitCode: item.exitCode ?? undefined,
            })),
          }
        : {}),
    };
  }
}

class RemoteLocalWorkerExecutor implements WorkerExecutor {
  constructor(
    readonly resource: WorkerResource,
    readonly connection: ConnectionResource,
    private readonly env: ForgeExecutionEnv,
    private readonly context: ForgeExecutionContext,
  ) {}

  async execute(
    request: WorkerExecutionRequest,
  ): Promise<WorkerExecutionResult> {
    const baseUrl =
      this.env.CONCLAVE_API_BASE_URL ?? this.env.CONCLAVE_LOCAL_RUNTIME_URL;
    const runtimeId = this.env.CONCLAVE_RUNTIME_ID;
    const token =
      this.env.CONCLAVE_RUNTIME_OPERATION_TOKEN ??
      this.env.CONCLAVE_LOCAL_RUNTIME_TOKEN;
    if (!baseUrl || !runtimeId || !token) {
      return {
        status: "failed",
        output: null,
        rawOutput: null,
        usage: { inputTokens: null, outputTokens: null },
        evidenceArtifactIds: [],
        error: {
          code: "local_runtime_not_configured",
          message: "Local Runtime worker channel is not configured",
          retryable: false,
        },
      };
    }
    const response = await fetch(
      `${baseUrl.replace(/\/$/, "")}/api/runtime/worker-execute`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
          "x-conclave-runtime-id": runtimeId,
        },
        body: JSON.stringify({
          type: "worker_execute",
          organizationId: this.context.organizationId,
          projectId: this.context.projectId,
          request,
        }),
      },
    );
    const body: unknown = await response.json();
    if (!response.ok) {
      return {
        status: "failed",
        output: null,
        rawOutput: null,
        usage: { inputTokens: null, outputTokens: null },
        evidenceArtifactIds: [],
        error: {
          code: "local_runtime_worker_request_failed",
          message: `Local Runtime worker request failed with ${response.status}`,
          retryable: response.status >= 500,
        },
      };
    }
    if (typeof body !== "object" || body === null) {
      throw new Error("Local Runtime worker returned an invalid result");
    }
    return body as WorkerExecutionResult;
  }
}

class AgentGatewayWorkerExecutor implements WorkerExecutor {
  constructor(
    readonly resource: WorkerResource,
    readonly connection: ConnectionResource,
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

    const baseUrl = this.env.CONCLAVE_API_BASE_URL;
    const token = this.env.CONCLAVE_FORGE_CALLBACK_TOKEN;
    if (!baseUrl || !token) {
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
    const response = await fetch(
      `${baseUrl.replace(/\/$/, "")}/api/internal/agent-assignments/dispatch`,
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
  binding: WorkerBinding,
  env: ForgeExecutionEnv,
  models: Readonly<Record<string, string>>,
  context: ForgeExecutionContext,
): WorkerExecutor {
  const { worker: resource, connection } = binding;
  if (connection.transport === "local_agent") {
    return new AgentGatewayWorkerExecutor(resource, connection, env, context);
  }
  const model = models[resource.id] ?? connection.name;
  if (connection.provider === "openai") {
    if (!env.CONCLAVE_OPENAI_API_KEY)
      throw new Error("OpenAI API key is not configured");
    return new OpenAIResponsesWorker({
      apiKey: env.CONCLAVE_OPENAI_API_KEY,
      model,
      resource,
      connection,
    });
  }
  if (connection.provider === "anthropic") {
    if (!env.CONCLAVE_ANTHROPIC_API_KEY)
      throw new Error("Anthropic API key is not configured");
    return new AnthropicMessagesWorker({
      apiKey: env.CONCLAVE_ANTHROPIC_API_KEY,
      model,
      resource,
      connection,
    });
  }
  throw new Error(
    `Unsupported model provider: ${connection.provider ?? connection.transport}`,
  );
}

async function readExecutionContext(
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
    "SELECT p.id AS project_id, p.repository_id FROM projects p JOIN goals g ON g.project_id = p.id WHERE g.id = ?1 AND p.organization_id = ?2",
  )
    .bind(goalId, organizationId)
    .first<{ project_id: string; repository_id: string | null }>();
  if (!project)
    throw new Error("Goal is not owned by the execution organization");
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
       w.id, w.agent_id, w.name, w.kind, w.roles_json, w.capabilities_json,
       w.permissions_json, w.independence_key, w.availability,
       c.id AS connection_id, c.name AS connection_name,
       c.transport, c.provider, c.adapter_version AS connection_adapter_version,
       c.auth_mode, c.billing_mode, c.cost_metadata_json,
       c.execution_environment, c.availability AS connection_availability
     FROM workers w
     JOIN worker_connections wc ON wc.worker_id = w.id
     JOIN connections c ON c.id = wc.connection_id
     WHERE w.organization_id = ?1
     ORDER BY wc.is_default DESC, c.id`,
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
  if (!leadResource || !implementerResource || !reviewerResource) {
    throw new Error(
      "Forge requires planning, implementation, and review workers",
    );
  }
  if (reviewerResource.worker.id === implementerResource.worker.id) {
    throw new Error("Forge requires independent worker resources");
  }
  const executionMode =
    params.executionMode === "cloud_api"
      ? "cloud_api"
      : params.executionMode === "multi_agent"
        ? "multi_agent"
        : "single_agent";
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
  const models = env.CONCLAVE_WORKER_MODELS
    ? (JSON.parse(env.CONCLAVE_WORKER_MODELS) as Record<string, string>)
    : {};
  const localBindings = [
    leadResource,
    implementerResource,
    reviewerResource,
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
      lead: modelFor(leadResource, env, models, context),
      implementer: modelFor(implementerResource, env, models, context),
      reviewer: modelFor(reviewerResource, env, models, context),
      ...(secondaryResearchResource
        ? {
            secondaryResearcher: modelFor(
              secondaryResearchResource,
              env,
              models,
              context,
            ),
          }
        : {}),
      requireSecondaryResearch: executionMode === "multi_agent",
      runtime: new RemoteLocalRuntime(env, context),
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
    if (
      request.method !== "POST" ||
      new URL(request.url).pathname !== "/execute"
    ) {
      return Response.json({ error: "not_found" }, { status: 404 });
    }
    const params = (await request.json()) as Record<string, unknown>;
    const executionId = crypto.randomUUID();
    ctx.waitUntil(this.runAndNotify(params, executionId));
    return Response.json({ executionId }, { status: 202 });
  }

  private async runAndNotify(
    params: Record<string, unknown>,
    executionId: string,
  ): Promise<void> {
    const runId = String(params.runId ?? "");
    const baseUrl = this.env.CONCLAVE_API_BASE_URL;
    if (!baseUrl) throw new Error("CONCLAVE_API_BASE_URL is not configured");
    try {
      const resultArtifactId = await executeForgeService(
        this.env,
        params,
        executionId,
      );
      await this.notify(baseUrl, runId, {
        eventId: crypto.randomUUID(),
        runId,
        executionId,
        status: "completed",
        resultArtifactId,
      });
    } catch (error) {
      await this.notify(baseUrl, runId, {
        eventId: crypto.randomUUID(),
        runId,
        executionId,
        status: "failed",
        error:
          error instanceof Error ? error.message : "Forge execution failed",
      });
    }
  }

  private async notify(
    baseUrl: string,
    runId: string,
    payload: Record<string, unknown>,
  ): Promise<void> {
    const response = await fetch(
      `${baseUrl.replace(/\/$/, "")}/api/runs/${encodeURIComponent(runId)}/forge-events`,
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
    if (!response.ok)
      throw new Error(`Forge callback failed with ${response.status}`);
  }
}

export default {
  fetch(request: Request, env: ForgeExecutionEnv, ctx: ExecutionContext) {
    return new ConclaveForgeExecutionService(env).fetch(request, ctx);
  },
};
