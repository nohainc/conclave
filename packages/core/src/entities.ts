/**
 * Conclave AX current Core domain entities.
 *
 * Core execution invariant:
 * Cloud orchestrates. Agents execute. Plugins integrate. Workers do the actual work. Studio controls and observes.
 */

export type WorkerAvailability =
  "available" | "busy" | "disabled" | "offline" | "draining";

export interface WorkerCostMetadata {
  readonly currency?: string;
  readonly estimatedCostMicrosPerAttempt: number | null;
  readonly inputMicrosPerMillionTokens?: number | null;
  readonly outputMicrosPerMillionTokens?: number | null;
  readonly [key: string]: unknown;
}

export interface Workspace {
  readonly id: string;
  readonly name: string;
  readonly slug: string;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface Project {
  readonly id: string;
  readonly workspaceId: string;
  readonly name: string;
  readonly description?: string | null;
  readonly repositoryId?: string | null;
  readonly settings: Record<string, unknown>;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export type ProjectRole = "lead" | "collaborator" | "viewer";

export interface ProjectMembership {
  readonly id: string;
  readonly projectId: string;
  readonly userId: string;
  readonly role: ProjectRole;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export type ChatStatus = "active" | "archived";

export interface Chat {
  readonly id: string;
  readonly projectId: string;
  readonly workspaceId: string;
  readonly createdByUserId: string;
  readonly title: string;
  readonly status: ChatStatus;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export type ChatMessageSenderType =
  "user" | "conclave" | "agent" | "worker" | "system";

export type ChatMessageKind =
  "user" | "conclave" | "status" | "approval" | "artifact" | "system";

export interface ChatMessage {
  readonly id: string;
  readonly chatId: string;
  readonly senderType: ChatMessageSenderType;
  readonly senderId: string;
  readonly content: string;
  readonly kind: ChatMessageKind;
  readonly goalId?: string | null;
  readonly metadata: Record<string, unknown>;
  readonly createdAt: string;
}

export type ExecutionHostStatus =
  "enrolled" | "online" | "offline" | "busy" | "draining" | "revoked";

export type ExecutionHostPlatform = "macos" | "linux" | "windows";
export type ExecutionHostArchitecture = "arm64" | "x64";

export interface ExecutionHostCapabilities {
  readonly os: ExecutionHostPlatform;
  readonly arch: ExecutionHostArchitecture;
  readonly version: string;
  readonly supportedRuntimes: readonly string[];
  readonly maxConcurrentWorkers: number;
  readonly customCapabilities?: readonly string[];
}

export interface ExecutionHost {
  readonly id: string;
  readonly workspaceId: string;
  readonly name: string;
  readonly hostname: string;
  readonly status: ExecutionHostStatus;
  readonly version: string;
  readonly capabilities: ExecutionHostCapabilities;
  readonly enrolledAt: string;
  readonly lastHeartbeatAt: string | null;
  readonly revokedAt: string | null;
}

export interface ExecutionHostEnrollment {
  readonly id: string;
  readonly workspaceId: string;
  readonly tokenHash: string;
  readonly expiresAt: string;
  readonly usedAt: string | null;
  readonly revokedAt: string | null;
  readonly createdBy: string;
}

export interface ExecutionHostSession {
  readonly id: string;
  readonly agentId: string;
  readonly workspaceId: string;
  readonly connectedAt: string;
  readonly lastHeartbeatAt: string;
  readonly disconnectedAt: string | null;
  readonly clientVersion: string;
  readonly protocolVersion: string;
  readonly ipAddress?: string;
}

export type ExecutionHostReleaseChannel = "stable" | "beta" | "development";

export interface ExecutionHostRelease {
  readonly version: string;
  readonly channel: ExecutionHostReleaseChannel;
  readonly minSupportedAgentVersion?: string | null;
  readonly supportedOS: readonly ExecutionHostPlatform[];
  readonly supportedArch: readonly ExecutionHostArchitecture[];
  readonly packageDigest: string;
  readonly packageR2Key: string;
  readonly signature: string;
  readonly releaseNotes?: string | null;
  readonly isRevoked: boolean;
  readonly revokedAt?: string | null;
  readonly revocationReason?: string | null;
  readonly createdAt: string;
}

export type WorkerCatalogStatus = "active" | "deprecated" | "revoked";

export interface WorkerCatalog {
  readonly id: string;
  readonly displayName: string;
  readonly description: string;
  readonly publisher: string;
  readonly supportedRoles: readonly string[];
  readonly supportedCapabilities: readonly string[];
  readonly status: WorkerCatalogStatus;
}

export type WorkerBillingMode =
  | "api_metered"
  | "subscription"
  | "local_compute"
  | "external"
  | "manual"
  | "free";

export type WorkerChannel = "stable" | "beta" | "development";

export interface WorkerVersion {
  readonly id: string;
  readonly workerCatalogId: string;
  readonly version: string;
  readonly channel: WorkerChannel;
  readonly protocolVersion: string;
  readonly minAgentVersion: string;
  readonly maxAgentVersion?: string;
  readonly supportedOs: readonly ExecutionHostPlatform[];
  readonly supportedArch: readonly ExecutionHostArchitecture[];
  readonly packageDigest: string;
  readonly packageR2Key: string;
  readonly signature: string;
  readonly permissions: readonly string[];
  readonly billingModes: readonly WorkerBillingMode[];
  readonly configSchema?: Record<string, unknown>;
  readonly secretSchema?: Record<string, unknown>;
  readonly isRevoked: boolean;
  readonly revokedAt?: string | null;
  readonly revocationReason?: string | null;
  readonly createdAt: string;
}

export type WorkerCostPolicy = WorkerCostMetadata;
export type WorkerStatus = WorkerAvailability;

export type WorkerSessionPolicy =
  "stateless" | "isolated_workspace" | "reuse_session" | "persistent_context";

export interface Worker {
  readonly id: string;
  readonly workspaceId: string;
  readonly agentId: string;
  readonly workerCatalogId: string;
  readonly workerVersionPolicy: string;
  readonly name: string;
  readonly roles: readonly string[];
  readonly capabilities: readonly string[];
  readonly config: Record<string, unknown>;
  readonly secretRefs: readonly string[];
  readonly enabled: boolean;
  readonly availability: WorkerAvailability;
  readonly billingMode: WorkerBillingMode;
  readonly costMetadata?: WorkerCostMetadata;
  readonly cost?: WorkerCostPolicy;
  readonly independenceKey: string;
  readonly concurrencyLimit: number;
  readonly sessionPolicy: WorkerSessionPolicy;
  readonly status?: WorkerStatus;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export type WorkerAssignmentStatus =
  | "created"
  | "dispatched"
  | "acknowledged"
  | "running"
  | "completed"
  | "failed"
  | "cancelled"
  | "timed_out";

export interface WorkerAssignment {
  readonly id: string;
  readonly workspaceId: string;
  readonly runId: string;
  readonly taskId: string;
  readonly attemptId: string;
  readonly agentId: string;
  readonly workerId: string;
  readonly workerCatalogId: string;
  readonly resolvedWorkerVersion?: string;
  readonly status: WorkerAssignmentStatus;
  readonly input: Record<string, unknown>;
  readonly idempotencyKey: string;
  readonly timeoutMs: number;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export type AssignmentTerminalStatus = "completed" | "failed" | "cancelled";

export interface AssignmentError {
  readonly code: string;
  readonly message: string;
  readonly retryable: boolean;
  readonly details?: Record<string, unknown>;
}

export interface WorkerAssignmentResult {
  readonly assignmentId: string;
  readonly workspaceId: string;
  readonly runId: string;
  readonly taskId: string;
  readonly attemptId: string;
  readonly agentId: string;
  readonly workerId: string;
  readonly status: AssignmentTerminalStatus;
  readonly output: Record<string, unknown> | null;
  readonly findings?: readonly unknown[];
  readonly artifactIds?: readonly string[];
  readonly error?: AssignmentError;
  readonly evidence?: {
    readonly observedAt: string;
    readonly metrics?: Record<string, unknown>;
    readonly logs?: readonly string[];
  };
  readonly completedAt: string;
}

export class DomainInvariantError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DomainInvariantError";
  }
}

/**
 * Validates invariants for a Conclave Workspace.
 */
export function validateWorkspace(workspace: Workspace): void {
  if (!workspace.id || workspace.id.trim().length === 0) {
    throw new DomainInvariantError("Workspace id is required");
  }
  if (!workspace.name || workspace.name.trim().length === 0) {
    throw new DomainInvariantError("Workspace name is required");
  }
  if (!workspace.slug || workspace.slug.trim().length === 0) {
    throw new DomainInvariantError("Workspace slug is required");
  }
}

/**
 * Validates invariants for a Project:
 * - Project belongs to exactly one Workspace
 * - Name is non-empty
 */
export function validateProject(project: Project, workspace?: Workspace): void {
  if (!project.id || project.id.trim().length === 0) {
    throw new DomainInvariantError("Project id is required");
  }
  if (!project.workspaceId || project.workspaceId.trim().length === 0) {
    throw new DomainInvariantError("Project workspaceId is required");
  }
  if (!project.name || project.name.trim().length === 0) {
    throw new DomainInvariantError("Project name is required");
  }
  if (workspace && workspace.id !== project.workspaceId) {
    throw new DomainInvariantError(
      `Cross-workspace violation: Project workspace '${project.workspaceId}' does not match Workspace '${workspace.id}'`,
    );
  }
}

/**
 * Validates invariants for a Chat:
 * - Chat belongs to a Project and a Workspace
 * - Created by a valid User
 * - Cross-workspace and cross-project invariant enforcement
 */
export function validateChat(
  chat: Chat,
  context?: { project?: Project; workspace?: Workspace },
): void {
  if (!chat.id || chat.id.trim().length === 0) {
    throw new DomainInvariantError("Chat id is required");
  }
  if (!chat.projectId || chat.projectId.trim().length === 0) {
    throw new DomainInvariantError("Chat projectId is required");
  }
  if (!chat.workspaceId || chat.workspaceId.trim().length === 0) {
    throw new DomainInvariantError("Chat workspaceId is required");
  }
  if (!chat.createdByUserId || chat.createdByUserId.trim().length === 0) {
    throw new DomainInvariantError("Chat createdByUserId is required");
  }
  if (!chat.title || chat.title.trim().length === 0) {
    throw new DomainInvariantError("Chat title is required");
  }

  if (context?.project) {
    if (context.project.id !== chat.projectId) {
      throw new DomainInvariantError(
        `Chat projectId '${chat.projectId}' does not match Project id '${context.project.id}'`,
      );
    }
    if (context.project.workspaceId !== chat.workspaceId) {
      throw new DomainInvariantError(
        `Cross-workspace violation: Chat workspace '${chat.workspaceId}' does not match Project workspace '${context.project.workspaceId}'`,
      );
    }
  }

  if (context?.workspace) {
    if (context.workspace.id !== chat.workspaceId) {
      throw new DomainInvariantError(
        `Cross-workspace violation: Chat workspace '${chat.workspaceId}' does not match Workspace id '${context.workspace.id}'`,
      );
    }
  }
}

/**
 * Validates invariants for a ChatMessage:
 * - Message belongs to a Chat
 * - Valid senderType, senderId, content, kind
 */
export function validateChatMessage(message: ChatMessage, chat?: Chat): void {
  if (!message.id || message.id.trim().length === 0) {
    throw new DomainInvariantError("ChatMessage id is required");
  }
  if (!message.chatId || message.chatId.trim().length === 0) {
    throw new DomainInvariantError("ChatMessage chatId is required");
  }
  if (!message.senderType) {
    throw new DomainInvariantError("ChatMessage senderType is required");
  }
  if (!message.senderId || message.senderId.trim().length === 0) {
    throw new DomainInvariantError("ChatMessage senderId is required");
  }
  if (typeof message.content !== "string") {
    throw new DomainInvariantError("ChatMessage content must be a string");
  }
  if (!message.kind) {
    throw new DomainInvariantError("ChatMessage kind is required");
  }

  if (chat && chat.id !== message.chatId) {
    throw new DomainInvariantError(
      `ChatMessage chatId '${message.chatId}' does not match target Chat id '${chat.id}'`,
    );
  }
}

/**
 * Validates invariants for a Conclave Agent.
 */
export function validateExecutionHost(agent: ExecutionHost): void {
  if (!agent.id || agent.id.trim().length === 0) {
    throw new DomainInvariantError("Agent id is required");
  }
  if (!agent.workspaceId || agent.workspaceId.trim().length === 0) {
    throw new DomainInvariantError("Agent workspaceId is required");
  }
  if (!agent.name || agent.name.trim().length === 0) {
    throw new DomainInvariantError("Agent name is required");
  }
  if (agent.capabilities.maxConcurrentWorkers < 1) {
    throw new DomainInvariantError(
      "Agent maxConcurrentWorkers must be at least 1",
    );
  }
}

/**
 * Validates invariants for an ExecutionHostRelease.
 */
export function validateExecutionHostRelease(
  release: ExecutionHostRelease,
): void {
  if (!release.version || release.version.trim().length === 0) {
    throw new DomainInvariantError("ExecutionHostRelease version is required");
  }
  if (!["stable", "beta", "development"].includes(release.channel)) {
    throw new DomainInvariantError(
      `Invalid ExecutionHostRelease channel '${release.channel}'. Must be stable, beta, or development`,
    );
  }
  if (!release.packageDigest || release.packageDigest.trim().length === 0) {
    throw new DomainInvariantError(
      "ExecutionHostRelease packageDigest is required",
    );
  }
  if (!release.packageR2Key || release.packageR2Key.trim().length === 0) {
    throw new DomainInvariantError(
      "ExecutionHostRelease packageR2Key is required",
    );
  }
  if (!release.signature || release.signature.trim().length === 0) {
    throw new DomainInvariantError(
      "ExecutionHostRelease signature is required",
    );
  }
  if (!release.supportedOS || release.supportedOS.length === 0) {
    throw new DomainInvariantError(
      "ExecutionHostRelease must support at least one OS",
    );
  }
  if (!release.supportedArch || release.supportedArch.length === 0) {
    throw new DomainInvariantError(
      "ExecutionHostRelease must support at least one architecture",
    );
  }
}

/**
 * Validates invariants for a WorkerCatalog:
 * - Plugin has id, displayName, publisher, and valid status
 */
export function validateWorkerCatalog(plugin: WorkerCatalog): void {
  if (!plugin.id || plugin.id.trim().length === 0) {
    throw new DomainInvariantError("WorkerCatalog id is required");
  }
  if (!plugin.displayName || plugin.displayName.trim().length === 0) {
    throw new DomainInvariantError("WorkerCatalog displayName is required");
  }
  if (!plugin.publisher || plugin.publisher.trim().length === 0) {
    throw new DomainInvariantError("WorkerCatalog publisher is required");
  }
  if (!plugin.status) {
    throw new DomainInvariantError("WorkerCatalog status is required");
  }
}

/**
 * Validates invariants for a WorkerVersion:
 * - Version belongs to a valid plugin
 * - Protocol version, digest, signature, and R2 key are present
 * - Valid release channel (stable, beta, development)
 */
export function validateWorkerVersion(
  version: WorkerVersion,
  parentPlugin?: WorkerCatalog,
): void {
  if (!version.id || version.id.trim().length === 0) {
    throw new DomainInvariantError("WorkerVersion id is required");
  }
  if (!version.workerCatalogId || version.workerCatalogId.trim().length === 0) {
    throw new DomainInvariantError("WorkerVersion workerCatalogId is required");
  }
  if (!version.version || version.version.trim().length === 0) {
    throw new DomainInvariantError("WorkerVersion version is required");
  }
  if (!["stable", "beta", "development"].includes(version.channel)) {
    throw new DomainInvariantError(
      `Invalid WorkerVersion channel '${version.channel}'. Must be stable, beta, or development`,
    );
  }
  if (!version.packageDigest || version.packageDigest.trim().length === 0) {
    throw new DomainInvariantError("WorkerVersion packageDigest is required");
  }
  if (!version.packageR2Key || version.packageR2Key.trim().length === 0) {
    throw new DomainInvariantError("WorkerVersion packageR2Key is required");
  }
  if (!version.signature || version.signature.trim().length === 0) {
    throw new DomainInvariantError("WorkerVersion signature is required");
  }

  if (parentPlugin) {
    if (parentPlugin.id !== version.workerCatalogId) {
      throw new DomainInvariantError(
        `Version workerCatalogId '${version.workerCatalogId}' does not match parent plugin id '${parentPlugin.id}'`,
      );
    }
  }
}

/**
 * Validates invariants for a Worker:
 * - Worker belongs to exactly one Workspace
 * - Worker is hosted by exactly one Agent
 * - Worker references one Plugin
 * - Cross-workspace references are forbidden
 */
export function validateWorker(
  worker: Worker,
  context?: { agent?: ExecutionHost; plugin?: WorkerCatalog },
): void {
  if (!worker.id || worker.id.trim().length === 0) {
    throw new DomainInvariantError("Worker id is required");
  }
  if (!worker.workspaceId || worker.workspaceId.trim().length === 0) {
    throw new DomainInvariantError(
      "Worker workspaceId is required (Worker must belong to one Workspace)",
    );
  }
  if (!worker.agentId || worker.agentId.trim().length === 0) {
    throw new DomainInvariantError(
      "Worker agentId is required (Worker must be hosted by one Agent)",
    );
  }
  if (!worker.workerCatalogId || worker.workerCatalogId.trim().length === 0) {
    throw new DomainInvariantError(
      "Worker workerCatalogId is required (Worker must reference one Plugin)",
    );
  }
  if (!worker.name || worker.name.trim().length === 0) {
    throw new DomainInvariantError("Worker name is required");
  }
  if (worker.roles.length === 0) {
    throw new DomainInvariantError("Worker must declare at least one role");
  }
  if (worker.capabilities.length === 0) {
    throw new DomainInvariantError(
      "Worker must declare at least one capability",
    );
  }
  if (!worker.independenceKey || worker.independenceKey.trim().length === 0) {
    throw new DomainInvariantError("Worker independenceKey is required");
  }
  if (worker.concurrencyLimit < 1) {
    throw new DomainInvariantError(
      "Worker concurrencyLimit must be at least 1",
    );
  }
  if (
    worker.sessionPolicy &&
    ![
      "stateless",
      "isolated_workspace",
      "reuse_session",
      "persistent_context",
    ].includes(worker.sessionPolicy)
  ) {
    throw new DomainInvariantError(
      `Invalid Worker sessionPolicy '${String(worker.sessionPolicy)}'`,
    );
  }
  const availability = worker.availability ?? worker.status;
  if (
    availability &&
    !["available", "busy", "disabled", "offline", "draining"].includes(
      availability,
    )
  ) {
    throw new DomainInvariantError(
      `Invalid Worker availability '${String(availability)}'`,
    );
  }

  if (context?.agent) {
    if (context.agent.id !== worker.agentId) {
      throw new DomainInvariantError(
        `Worker agentId '${worker.agentId}' does not match host Agent id '${context.agent.id}'`,
      );
    }
    if (context.agent.workspaceId !== worker.workspaceId) {
      throw new DomainInvariantError(
        `Cross-workspace violation: Worker workspace '${worker.workspaceId}' does not match Agent workspace '${context.agent.workspaceId}'`,
      );
    }
    if (context.agent.status === "revoked") {
      throw new DomainInvariantError(
        `Cannot assign or configure Worker on revoked Agent '${context.agent.id}'`,
      );
    }
  }

  if (context?.plugin) {
    if (context.plugin.id !== worker.workerCatalogId) {
      throw new DomainInvariantError(
        `Worker workerCatalogId '${worker.workerCatalogId}' does not match Plugin id '${context.plugin.id}'`,
      );
    }
    if (context.plugin.status === "revoked") {
      throw new DomainInvariantError(
        `Worker references revoked Plugin '${context.plugin.id}'`,
      );
    }
  }
}

/**
 * Validates invariants for a Worker Assignment:
 * - Assignment targets exactly one Worker
 * - Assignment corresponds to exactly one Attempt
 * - Assignment must match Worker's workspace and host Agent
 */
export function validateAssignment(
  assignment: WorkerAssignment,
  context?: { worker?: Worker; attemptId?: string },
): void {
  if (!assignment.id || assignment.id.trim().length === 0) {
    throw new DomainInvariantError("Assignment id is required");
  }
  if (!assignment.workspaceId || assignment.workspaceId.trim().length === 0) {
    throw new DomainInvariantError("Assignment workspaceId is required");
  }
  if (!assignment.runId || assignment.runId.trim().length === 0) {
    throw new DomainInvariantError("Assignment runId is required");
  }
  if (!assignment.taskId || assignment.taskId.trim().length === 0) {
    throw new DomainInvariantError("Assignment taskId is required");
  }
  if (!assignment.attemptId || assignment.attemptId.trim().length === 0) {
    throw new DomainInvariantError(
      "Assignment attemptId is required (Assignment corresponds to one Attempt)",
    );
  }
  if (!assignment.agentId || assignment.agentId.trim().length === 0) {
    throw new DomainInvariantError("Assignment agentId is required");
  }
  if (!assignment.workerId || assignment.workerId.trim().length === 0) {
    throw new DomainInvariantError(
      "Assignment workerId is required (Assignment targets exactly one Worker)",
    );
  }
  if (
    !assignment.workerCatalogId ||
    assignment.workerCatalogId.trim().length === 0
  ) {
    throw new DomainInvariantError("Assignment workerCatalogId is required");
  }
  if (
    !assignment.idempotencyKey ||
    assignment.idempotencyKey.trim().length === 0
  ) {
    throw new DomainInvariantError("Assignment idempotencyKey is required");
  }

  if (context?.attemptId && context.attemptId !== assignment.attemptId) {
    throw new DomainInvariantError(
      `Assignment attemptId '${assignment.attemptId}' does not match target attempt '${context.attemptId}'`,
    );
  }

  if (context?.worker) {
    if (context.worker.id !== assignment.workerId) {
      throw new DomainInvariantError(
        `Assignment workerId '${assignment.workerId}' does not match Worker id '${context.worker.id}'`,
      );
    }
    if (context.worker.workspaceId !== assignment.workspaceId) {
      throw new DomainInvariantError(
        `Cross-workspace violation: Assignment workspace '${assignment.workspaceId}' does not match Worker workspace '${context.worker.workspaceId}'`,
      );
    }
    if (context.worker.agentId !== assignment.agentId) {
      throw new DomainInvariantError(
        `Assignment agentId '${assignment.agentId}' does not match Worker host Agent '${context.worker.agentId}'`,
      );
    }
    if (context.worker.workerCatalogId !== assignment.workerCatalogId) {
      throw new DomainInvariantError(
        `Assignment workerCatalogId '${assignment.workerCatalogId}' does not match Worker plugin '${context.worker.workerCatalogId}'`,
      );
    }
    if (!context.worker.enabled || context.worker.status === "disabled") {
      throw new DomainInvariantError(
        `Cannot dispatch assignment to disabled Worker '${context.worker.id}'`,
      );
    }
  }
}

/**
 * Validates a WorkerAssignmentResult.
 * Ensures the result strictly answers the assigned execution and enforces the invariant:
 * "Agent does not create follow-up Tasks".
 */
export function validateAssignmentResult(
  result: WorkerAssignmentResult,
  assignment?: WorkerAssignment,
): void {
  if (!result.assignmentId || result.assignmentId.trim().length === 0) {
    throw new DomainInvariantError("Result assignmentId is required");
  }
  if (!result.attemptId || result.attemptId.trim().length === 0) {
    throw new DomainInvariantError("Result attemptId is required");
  }
  if (!result.status) {
    throw new DomainInvariantError("Result terminal status is required");
  }

  if (assignment) {
    if (result.assignmentId !== assignment.id) {
      throw new DomainInvariantError(
        `Result assignmentId '${result.assignmentId}' does not match Assignment id '${assignment.id}'`,
      );
    }
    if (result.workspaceId !== assignment.workspaceId) {
      throw new DomainInvariantError(
        `Result workspaceId '${result.workspaceId}' does not match Assignment workspace '${assignment.workspaceId}'`,
      );
    }
    if (
      result.runId !== assignment.runId ||
      result.taskId !== assignment.taskId ||
      result.attemptId !== assignment.attemptId
    ) {
      throw new DomainInvariantError(
        "Result runId/taskId/attemptId does not match Assignment target",
      );
    }
    if (
      result.workerId !== assignment.workerId ||
      result.agentId !== assignment.agentId
    ) {
      throw new DomainInvariantError(
        "Result workerId/agentId does not match Assignment executing worker/agent",
      );
    }
  }
}
