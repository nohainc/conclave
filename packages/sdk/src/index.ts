export type JsonValue =
  | string
  | number
  | boolean
  | null
  | JsonValue[]
  | { readonly [key: string]: JsonValue };

export interface ExtensionDescriptor {
  readonly id: string;
  readonly name: string;
  readonly version: string;
  readonly capabilities: readonly string[];
}

export interface ProviderRequest {
  readonly protocol: string;
  readonly payload: JsonValue;
  readonly signal?: AbortSignal;
}

export interface ProviderResponse {
  readonly requestId: string;
  readonly payload: JsonValue;
  readonly usage?: {
    readonly inputTokens?: number;
    readonly outputTokens?: number;
    readonly costMicros?: number;
  };
}

export interface ProviderAdapter {
  readonly descriptor: ExtensionDescriptor;
  invoke(request: ProviderRequest): Promise<ProviderResponse>;
}

export interface AgentRequest {
  readonly objective: string;
  readonly input: JsonValue;
  readonly signal?: AbortSignal;
}

export interface AgentResponse {
  readonly output: JsonValue;
  readonly evidence: readonly JsonValue[];
}

export interface AgentAdapter {
  readonly descriptor: ExtensionDescriptor;
  execute(request: AgentRequest): Promise<AgentResponse>;
}

export interface ToolContext {
  readonly runId: string;
  readonly grantedPermissions: ReadonlySet<string>;
  readonly signal?: AbortSignal;
}

export interface ExternalTool {
  readonly descriptor: ExtensionDescriptor;
  readonly requiredPermissions: readonly string[];
  execute(input: JsonValue, context: ToolContext): Promise<JsonValue>;
}

export function assertToolPermissions(
  tool: ExternalTool,
  grantedPermissions: ReadonlySet<string>,
): void {
  const missing = tool.requiredPermissions.find(
    (permission) => !grantedPermissions.has(permission),
  );
  if (missing)
    throw new Error(`Missing permission ${missing} for ${tool.descriptor.id}`);
}

export interface ExtensionRegistry {
  registerProvider(provider: ProviderAdapter): void;
  registerAgent(agent: AgentAdapter): void;
  registerTool(tool: ExternalTool): void;
  provider(id: string): ProviderAdapter | undefined;
  agent(id: string): AgentAdapter | undefined;
  tool(id: string): ExternalTool | undefined;
}

export class InMemoryExtensionRegistry implements ExtensionRegistry {
  private readonly providers = new Map<string, ProviderAdapter>();
  private readonly agents = new Map<string, AgentAdapter>();
  private readonly tools = new Map<string, ExternalTool>();

  registerProvider(provider: ProviderAdapter): void {
    this.register(this.providers, provider);
  }
  registerAgent(agent: AgentAdapter): void {
    this.register(this.agents, agent);
  }
  registerTool(tool: ExternalTool): void {
    this.register(this.tools, tool);
  }
  provider(id: string): ProviderAdapter | undefined {
    return this.providers.get(id);
  }
  agent(id: string): AgentAdapter | undefined {
    return this.agents.get(id);
  }
  tool(id: string): ExternalTool | undefined {
    return this.tools.get(id);
  }

  private register<T extends { descriptor: ExtensionDescriptor }>(
    map: Map<string, T>,
    extension: T,
  ): void {
    if (!extension.descriptor.id || !extension.descriptor.version) {
      throw new Error("Extension id and version are required");
    }
    if (map.has(extension.descriptor.id)) {
      throw new Error(
        `Extension ${extension.descriptor.id} is already registered`,
      );
    }
    map.set(extension.descriptor.id, extension);
  }
}

export type WorkflowStep =
  | {
      readonly id: string;
      readonly kind: "provider";
      readonly providerId: string;
      readonly protocol: string;
      readonly input: JsonValue;
      readonly dependsOn?: readonly string[];
    }
  | {
      readonly id: string;
      readonly kind: "agent";
      readonly agentId: string;
      readonly objective: string;
      readonly input: JsonValue;
      readonly dependsOn?: readonly string[];
    }
  | {
      readonly id: string;
      readonly kind: "tool";
      readonly toolId: string;
      readonly input: JsonValue;
      readonly dependsOn?: readonly string[];
    }
  | {
      readonly id: string;
      readonly kind: "ci";
      readonly workerId: string;
      readonly command: readonly string[];
      readonly dependsOn?: readonly string[];
    }
  | {
      readonly id: string;
      readonly kind: "approval";
      readonly prompt: string;
      readonly dependsOn?: readonly string[];
    };

export interface WorkflowTemplate {
  readonly protocol: "conclave.workflow";
  readonly version: 1;
  readonly id: string;
  readonly name: string;
  readonly steps: readonly WorkflowStep[];
}

export function validateWorkflowTemplate(template: WorkflowTemplate): void {
  if (template.protocol !== "conclave.workflow" || template.version !== 1) {
    throw new Error("Unsupported workflow template version");
  }
  if (!template.id || template.steps.length === 0) {
    throw new Error("Workflow id and at least one step are required");
  }
  const ids = new Set<string>();
  for (const step of template.steps) {
    if (!step.id || ids.has(step.id))
      throw new Error(`Duplicate step ${step.id}`);
    ids.add(step.id);
  }
  const dependencies = new Map(
    template.steps.map((step) => [step.id, step.dependsOn ?? []]),
  );
  for (const [id, dependsOn] of dependencies) {
    for (const dependency of dependsOn) {
      if (!ids.has(dependency))
        throw new Error(`Unknown dependency ${dependency} for ${id}`);
    }
  }
  const visiting = new Set<string>();
  const visited = new Set<string>();
  const visit = (id: string): void => {
    if (visiting.has(id)) throw new Error(`Workflow dependency cycle at ${id}`);
    if (visited.has(id)) return;
    visiting.add(id);
    for (const dependency of dependencies.get(id) ?? []) visit(dependency);
    visiting.delete(id);
    visited.add(id);
  };
  for (const id of ids) visit(id);
}

export interface RunnerHandlers {
  readonly provider: (
    step: Extract<WorkflowStep, { kind: "provider" }>,
  ) => Promise<JsonValue>;
  readonly agent: (
    step: Extract<WorkflowStep, { kind: "agent" }>,
  ) => Promise<JsonValue>;
  readonly tool: (
    step: Extract<WorkflowStep, { kind: "tool" }>,
  ) => Promise<JsonValue>;
  readonly ci: (
    step: Extract<WorkflowStep, { kind: "ci" }>,
  ) => Promise<JsonValue>;
}

export interface ApprovalRequest {
  readonly stepId: string;
  readonly prompt: string;
}

export interface RunnerEvent {
  readonly type:
    "step_started" | "step_succeeded" | "approval_requested" | "cancelled";
  readonly stepId?: string;
  readonly payload?: JsonValue;
}

export interface RunnerSnapshot {
  readonly status:
    "running" | "awaiting_approval" | "completed" | "cancelled" | "failed";
  readonly completedStepIds: readonly string[];
  readonly results: Readonly<Record<string, JsonValue>>;
  readonly approval?: ApprovalRequest;
  readonly error?: string;
}

export interface HeadlessRunnerOptions {
  readonly template: WorkflowTemplate;
  readonly handlers: RunnerHandlers;
  readonly grantedPermissions?: ReadonlySet<string>;
  readonly onEvent?: (event: RunnerEvent) => void;
}

export class HeadlessRunner {
  private readonly template: WorkflowTemplate;
  private readonly handlers: RunnerHandlers;
  private readonly grantedPermissions: ReadonlySet<string>;
  private readonly onEvent: (event: RunnerEvent) => void;
  private readonly completed = new Set<string>();
  private readonly results: Record<string, JsonValue> = {};
  private cancelled = false;
  private approval: ApprovalRequest | undefined;
  private failure: string | undefined;

  constructor(options: HeadlessRunnerOptions) {
    validateWorkflowTemplate(options.template);
    this.template = options.template;
    this.handlers = options.handlers;
    this.grantedPermissions = options.grantedPermissions ?? new Set();
    this.onEvent = options.onEvent ?? (() => undefined);
  }

  cancel(): RunnerSnapshot {
    this.cancelled = true;
    this.onEvent({ type: "cancelled" });
    return this.snapshot();
  }

  async start(): Promise<RunnerSnapshot> {
    return this.advance();
  }

  async approve(approved: boolean): Promise<RunnerSnapshot> {
    if (!this.approval) throw new Error("No approval is pending");
    const stepId = this.approval.stepId;
    this.approval = undefined;
    if (!approved) {
      this.failure = `Approval rejected for ${stepId}`;
      return this.snapshot();
    }
    this.completed.add(stepId);
    this.results[stepId] = { approved: true };
    this.onEvent({
      type: "step_succeeded",
      stepId,
      payload: this.results[stepId],
    });
    return this.advance();
  }

  private async advance(): Promise<RunnerSnapshot> {
    if (this.cancelled || this.failure || this.approval) return this.snapshot();
    while (this.completed.size < this.template.steps.length) {
      if (this.cancelled || this.failure || this.approval) break;
      const next = this.template.steps.find(
        (step) =>
          !this.completed.has(step.id) &&
          (step.dependsOn ?? []).every((dependency) =>
            this.completed.has(dependency),
          ),
      );
      if (!next) {
        this.failure = "Workflow cannot make progress";
        break;
      }
      if (next.kind === "approval") {
        this.approval = { stepId: next.id, prompt: next.prompt };
        this.onEvent({ type: "approval_requested", stepId: next.id });
        break;
      }
      try {
        this.onEvent({ type: "step_started", stepId: next.id });
        const result = await this.execute(next);
        this.results[next.id] = result;
        this.completed.add(next.id);
        this.onEvent({
          type: "step_succeeded",
          stepId: next.id,
          payload: result,
        });
      } catch (error) {
        this.failure =
          error instanceof Error ? error.message : "Workflow step failed";
      }
    }
    return this.snapshot();
  }

  private async execute(
    step: Exclude<WorkflowStep, { kind: "approval" }>,
  ): Promise<JsonValue> {
    if (step.kind === "provider") return this.handlers.provider(step);
    if (step.kind === "agent") return this.handlers.agent(step);
    if (step.kind === "ci") return this.handlers.ci(step);
    return this.handlers.tool(step);
  }

  private snapshot(): RunnerSnapshot {
    const status = this.cancelled
      ? "cancelled"
      : this.failure
        ? "failed"
        : this.approval
          ? "awaiting_approval"
          : this.completed.size === this.template.steps.length
            ? "completed"
            : "running";
    return {
      status,
      completedStepIds: [...this.completed],
      results: { ...this.results },
      ...(this.approval ? { approval: this.approval } : {}),
      ...(this.failure ? { error: this.failure } : {}),
    };
  }
}
