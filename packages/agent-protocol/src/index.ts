import { z } from "zod";

export const AGENT_PROTOCOL_NAME = "conclave.agent-protocol" as const;
export const AGENT_PROTOCOL_VERSION = "2.0" as const;

const protocolVersionPattern = /^\d+\.\d+(?:\.\d+)?$/;

function protocolVersionParts(version: string): [number, number] {
  if (!protocolVersionPattern.test(version)) {
    throw new Error(`Invalid agent protocol version: ${version}`);
  }
  const [major, minor] = version.split(".").map(Number);
  return [major ?? 0, minor ?? 0];
}

/**
 * A peer may add fields in a newer minor version, but a major-version change
 * is incompatible. The local version is the minimum minor version this
 * implementation understands.
 */
export function isCompatibleAgentProtocolVersion(
  local: string,
  remote: string,
): boolean {
  const [localMajor, localMinor] = protocolVersionParts(local);
  const [remoteMajor, remoteMinor] = protocolVersionParts(remote);
  return localMajor === remoteMajor && remoteMinor >= localMinor;
}

export const MAX_MESSAGE_SIZE_BYTES = 4 * 1024 * 1024; // 4MB safe frame limit

const nonEmptyStr = z.string().trim().min(1);
const timestampStr = z.string().datetime();

// Base envelope fields present on every agent protocol message
const baseEnvelopeFields = {
  protocol: z.literal(AGENT_PROTOCOL_NAME),
  protocolVersion: z.string().regex(protocolVersionPattern),
  messageId: nonEmptyStr,
  correlationId: nonEmptyStr.optional(),
  timestamp: timestampStr,
};

// Standard execution correlation fields mandatory for ALL assignment messages
export const assignmentEnvelopeFields = {
  ...baseEnvelopeFields,
  workspaceId: nonEmptyStr,
  agentId: nonEmptyStr,
  workerId: nonEmptyStr,
  runId: nonEmptyStr,
  taskId: nonEmptyStr,
  attemptId: nonEmptyStr,
  assignmentId: nonEmptyStr,
  idempotencyKey: nonEmptyStr,
};

// ==========================================
// 1. Agent Lifecycle & Presence
// ==========================================

export const AgentCapabilitiesSchema = z
  .object({
    os: z.enum(["macos", "linux", "windows"]),
    arch: z.enum(["arm64", "x64"]),
    agentVersion: nonEmptyStr,
    supportedRuntimes: z.array(nonEmptyStr),
    maxConcurrentWorkers: z.number().int().min(1),
    customCapabilities: z.array(nonEmptyStr).optional(),
  })
  .strict();
export type AgentCapabilities = z.infer<typeof AgentCapabilitiesSchema>;

export const AgentHelloPayloadSchema = z
  .object({
    agentId: nonEmptyStr,
    workspaceId: nonEmptyStr,
    name: nonEmptyStr,
    hostname: nonEmptyStr,
    agentVersion: nonEmptyStr,
    capabilities: AgentCapabilitiesSchema,
    authCredentials: z.record(z.string(), z.string()).optional(),
  })
  .strict();
export type AgentHelloPayload = z.infer<typeof AgentHelloPayloadSchema>;

export const AgentHelloAckPayloadSchema = z
  .object({
    sessionId: nonEmptyStr,
    heartbeatIntervalMs: z.number().int().min(1000),
    serverTime: timestampStr,
    serverVersion: nonEmptyStr,
  })
  .strict();
export type AgentHelloAckPayload = z.infer<typeof AgentHelloAckPayloadSchema>;

export const AgentHeartbeatPayloadSchema = z
  .object({
    agentId: nonEmptyStr,
    workspaceId: nonEmptyStr,
    sessionId: nonEmptyStr,
    status: z.enum(["online", "busy", "draining"]),
    activeWorkers: z.number().int().nonnegative(),
    activeAssignments: z.number().int().nonnegative(),
    cpuPercent: z.number().min(0).max(100).optional(),
    memoryFreeBytes: z.number().nonnegative().optional(),
  })
  .strict();
export type AgentHeartbeatPayload = z.infer<typeof AgentHeartbeatPayloadSchema>;

export const AgentHeartbeatAckPayloadSchema = z
  .object({
    acknowledged: z.boolean(),
    serverTime: timestampStr,
  })
  .strict();
export type AgentHeartbeatAckPayload = z.infer<
  typeof AgentHeartbeatAckPayloadSchema
>;

export const AgentSyncRequestPayloadSchema = z
  .object({
    agentId: nonEmptyStr,
    workspaceId: nonEmptyStr,
    installedPluginVersions: z.record(nonEmptyStr, nonEmptyStr),
    activeWorkerIds: z.array(nonEmptyStr),
    unreconciledAssignmentIds: z.array(nonEmptyStr).optional(),
  })
  .strict();
export type AgentSyncRequestPayload = z.infer<
  typeof AgentSyncRequestPayloadSchema
>;

export const DesiredPluginSchema = z
  .object({
    pluginId: nonEmptyStr,
    version: nonEmptyStr,
    publisher: nonEmptyStr,
    protocolVersion: nonEmptyStr.optional(),
    minAgentVersion: nonEmptyStr.optional(),
    supportedPlatforms: z.array(nonEmptyStr).optional(),
    packageR2Key: nonEmptyStr,
    packageDigest: nonEmptyStr,
    signature: nonEmptyStr,
    permissions: z.array(nonEmptyStr),
  })
  .strict();
export type DesiredPlugin = z.infer<typeof DesiredPluginSchema>;

export const DesiredWorkerSchema = z
  .object({
    id: z.string().optional(),
    workerId: nonEmptyStr,
    workspaceId: z.string().optional(),
    agentId: z.string().optional(),
    pluginId: nonEmptyStr,
    pluginVersionPolicy: nonEmptyStr,
    name: nonEmptyStr,
    roles: z.array(nonEmptyStr).min(1),
    capabilities: z.array(nonEmptyStr).min(1),
    config: z.record(z.string(), z.unknown()),
    secretRefs: z.array(nonEmptyStr),
    enabled: z.boolean(),
    availability: z
      .enum(["available", "busy", "disabled", "offline", "draining"])
      .optional(),
    billingMode: z.enum([
      "api_metered",
      "subscription",
      "local_compute",
      "external",
      "manual",
      "free",
    ]),
    costMetadata: z.record(z.string(), z.unknown()).optional(),
    independenceKey: nonEmptyStr,
    concurrencyLimit: z.number().int().min(1),
    sessionPolicy: z
      .enum([
        "stateless",
        "isolated_workspace",
        "reuse_session",
        "persistent_context",
      ])
      .optional(),
  })
  .strict();
export type DesiredWorker = z.infer<typeof DesiredWorkerSchema>;

export const AgentSyncResponsePayloadSchema = z
  .object({
    desiredPlugins: z.array(DesiredPluginSchema),
    desiredWorkers: z.array(DesiredWorkerSchema),
    activeAssignmentIds: z.array(nonEmptyStr),
    assignmentStates: z
      .array(
        z
          .object({
            assignmentId: nonEmptyStr,
            attemptId: nonEmptyStr,
            idempotencyKey: nonEmptyStr,
            status: nonEmptyStr,
          })
          .strict(),
      )
      .optional(),
  })
  .strict();
export type AgentSyncResponsePayload = z.infer<
  typeof AgentSyncResponsePayloadSchema
>;

export const AgentUpdateAvailablePayloadSchema = z
  .object({
    version: nonEmptyStr,
    channel: z.enum(["stable", "beta", "development"]),
    packageR2Key: nonEmptyStr,
    packageDigest: nonEmptyStr,
    signature: nonEmptyStr,
    releaseNotes: z.string().optional(),
    minSupportedAgentVersion: z.string().optional(),
  })
  .strict();
export type AgentUpdateAvailablePayload = z.infer<
  typeof AgentUpdateAvailablePayloadSchema
>;

export const AgentUpdateStatusPayloadSchema = z
  .object({
    fromVersion: nonEmptyStr,
    targetVersion: nonEmptyStr,
    status: z.enum([
      "checking",
      "downloading",
      "verifying",
      "staged",
      "draining",
      "applying",
      "health_checking",
      "completed",
      "failed",
      "rolled_back",
    ]),
    error: z.string().optional(),
  })
  .strict();
export type AgentUpdateStatusPayload = z.infer<
  typeof AgentUpdateStatusPayloadSchema
>;

// ==========================================
// 2. Plugin Management
// ==========================================

export const PluginInstallPayloadSchema = z
  .object({
    pluginId: nonEmptyStr,
    version: nonEmptyStr,
    packageUrl: nonEmptyStr.optional(),
    packageR2Key: nonEmptyStr,
    packageDigest: nonEmptyStr,
    signature: nonEmptyStr,
    permissions: z.array(nonEmptyStr),
    configSchema: z.record(z.string(), z.unknown()).optional(),
  })
  .strict();
export type PluginInstallPayload = z.infer<typeof PluginInstallPayloadSchema>;

export const PluginUpdatePayloadSchema = z
  .object({
    pluginId: nonEmptyStr,
    fromVersion: nonEmptyStr,
    toVersion: nonEmptyStr,
    packageR2Key: nonEmptyStr,
    packageDigest: nonEmptyStr,
    signature: nonEmptyStr,
    permissions: z.array(nonEmptyStr),
  })
  .strict();
export type PluginUpdatePayload = z.infer<typeof PluginUpdatePayloadSchema>;

export const PluginRemovePayloadSchema = z
  .object({
    pluginId: nonEmptyStr,
    version: nonEmptyStr,
    force: z.boolean().default(false),
  })
  .strict();
export type PluginRemovePayload = z.infer<typeof PluginRemovePayloadSchema>;

export const PluginStatusItemSchema = z
  .object({
    pluginId: nonEmptyStr,
    version: nonEmptyStr,
    status: z.enum(["installing", "installed", "active", "error", "removed"]),
    error: nonEmptyStr.optional(),
    installedAt: timestampStr,
  })
  .strict();
export type PluginStatusItem = z.infer<typeof PluginStatusItemSchema>;

export const PluginStatusPayloadSchema = z
  .object({
    plugins: z.array(PluginStatusItemSchema),
  })
  .strict();
export type PluginStatusPayload = z.infer<typeof PluginStatusPayloadSchema>;

// ==========================================
// 3. Worker Configuration & Health
// ==========================================

export const WorkerConfigurePayloadSchema = z
  .object({
    worker: DesiredWorkerSchema,
  })
  .strict();
export type WorkerConfigurePayload = z.infer<
  typeof WorkerConfigurePayloadSchema
>;

export const WorkerStatusPayloadSchema = z
  .object({
    workerId: nonEmptyStr,
    agentId: nonEmptyStr,
    status: z.enum(["available", "busy", "disabled", "error", "offline"]),
    activeAssignments: z.number().int().nonnegative(),
    healthDetail: nonEmptyStr.optional(),
    missingSecrets: z.array(nonEmptyStr).optional(),
  })
  .strict();
export type WorkerStatusPayload = z.infer<typeof WorkerStatusPayloadSchema>;

// ==========================================
// 4. Assignment Execution
// ==========================================

export const AssignmentStartPayloadSchema = z
  .object({
    objective: nonEmptyStr,
    role: nonEmptyStr,
    pluginId: nonEmptyStr,
    resolvedPluginVersion: nonEmptyStr,
    input: z.record(z.string(), z.unknown()),
    contextArtifactIds: z.array(nonEmptyStr),
    timeoutMs: z.number().int().min(1000),
    repository: z
      .object({
        repositoryId: nonEmptyStr,
        revision: nonEmptyStr,
        workspaceSubpath: z.string().optional(),
      })
      .optional(),
  })
  .strict();
export type AssignmentStartPayload = z.infer<
  typeof AssignmentStartPayloadSchema
>;

export const AssignmentAckPayloadSchema = z
  .object({
    accepted: z.boolean(),
    reason: nonEmptyStr.optional(),
    estimatedStartMs: z.number().int().nonnegative().optional(),
  })
  .strict();
export type AssignmentAckPayload = z.infer<typeof AssignmentAckPayloadSchema>;

export const AssignmentProgressPayloadSchema = z
  .object({
    stage: nonEmptyStr,
    percentComplete: z.number().min(0).max(100).optional(),
    logChunk: z.string().optional(),
    interimArtifactIds: z.array(nonEmptyStr).optional(),
  })
  .strict();
export type AssignmentProgressPayload = z.infer<
  typeof AssignmentProgressPayloadSchema
>;

export const AssignmentErrorSchema = z
  .object({
    code: nonEmptyStr,
    message: nonEmptyStr,
    retryable: z.boolean(),
    details: z.record(z.string(), z.unknown()).optional(),
  })
  .strict();
export type AssignmentError = z.infer<typeof AssignmentErrorSchema>;

export const AssignmentResultPayloadSchema = z
  .object({
    status: z.literal("completed"),
    summary: nonEmptyStr,
    output: z.record(z.string(), z.unknown()).nullable(),
    artifactIds: z.array(nonEmptyStr),
    findings: z.array(z.unknown()).optional(),
    evidence: z
      .object({
        observedAt: timestampStr,
        metrics: z.record(z.string(), z.unknown()).optional(),
        logs: z.array(z.string()).optional(),
      })
      .optional(),
  })
  .strict();
export type AssignmentResultPayload = z.infer<
  typeof AssignmentResultPayloadSchema
>;

export const AssignmentFailurePayloadSchema = z
  .object({
    status: z.literal("failed"),
    error: AssignmentErrorSchema,
    artifactIds: z.array(nonEmptyStr).optional(),
  })
  .strict();
export type AssignmentFailurePayload = z.infer<
  typeof AssignmentFailurePayloadSchema
>;

export const AssignmentCancelledPayloadSchema = z
  .object({
    status: z.literal("cancelled"),
    reason: nonEmptyStr,
  })
  .strict();
export type AssignmentCancelledPayload = z.infer<
  typeof AssignmentCancelledPayloadSchema
>;

export const AssignmentCancelPayloadSchema = z
  .object({
    reason: nonEmptyStr,
    gracePeriodMs: z.number().int().min(0).default(5000),
  })
  .strict();
export type AssignmentCancelPayload = z.infer<
  typeof AssignmentCancelPayloadSchema
>;

export const AssignmentCancelAckPayloadSchema = z
  .object({
    cancelled: z.boolean(),
    alreadyTerminated: z.boolean().default(false),
  })
  .strict();
export type AssignmentCancelAckPayload = z.infer<
  typeof AssignmentCancelAckPayloadSchema
>;

// ==========================================
// Discriminated Protocol Message Envelopes
// ==========================================

const agentMessage = <TType extends string, TPayload extends z.ZodType>(
  type: TType,
  payload: TPayload,
) =>
  z
    .object({
      ...baseEnvelopeFields,
      type: z.literal(type),
      payload,
    })
    .strict();

const assignmentMessage = <TType extends string, TPayload extends z.ZodType>(
  type: TType,
  payload: TPayload,
) =>
  z
    .object({
      ...assignmentEnvelopeFields,
      type: z.literal(type),
      payload,
    })
    .strict();

export const AgentProtocolMessageSchema = z.discriminatedUnion("type", [
  // Agent management
  agentMessage("agent.hello", AgentHelloPayloadSchema),
  agentMessage("agent.hello.ack", AgentHelloAckPayloadSchema),
  agentMessage("agent.heartbeat", AgentHeartbeatPayloadSchema),
  agentMessage("agent.heartbeat.ack", AgentHeartbeatAckPayloadSchema),
  agentMessage("agent.sync.request", AgentSyncRequestPayloadSchema),
  agentMessage("agent.sync.response", AgentSyncResponsePayloadSchema),
  agentMessage("agent.capabilities", AgentCapabilitiesSchema),
  agentMessage("agent.update.available", AgentUpdateAvailablePayloadSchema),
  agentMessage("agent.update.status", AgentUpdateStatusPayloadSchema),

  // Plugins
  agentMessage("plugin.install", PluginInstallPayloadSchema),
  agentMessage("plugin.update", PluginUpdatePayloadSchema),
  agentMessage("plugin.remove", PluginRemovePayloadSchema),
  agentMessage("plugin.status", PluginStatusPayloadSchema),

  // Workers
  agentMessage("worker.configure", WorkerConfigurePayloadSchema),
  agentMessage("worker.status", WorkerStatusPayloadSchema),

  // Assignments (strictly correlation-enveloped)
  assignmentMessage("assignment.start", AssignmentStartPayloadSchema),
  assignmentMessage("assignment.ack", AssignmentAckPayloadSchema),
  assignmentMessage("assignment.progress", AssignmentProgressPayloadSchema),
  assignmentMessage("assignment.result", AssignmentResultPayloadSchema),
  assignmentMessage("assignment.error", AssignmentFailurePayloadSchema),
  assignmentMessage("assignment.cancelled", AssignmentCancelledPayloadSchema),
  assignmentMessage("assignment.cancel", AssignmentCancelPayloadSchema),
  assignmentMessage("assignment.cancel.ack", AssignmentCancelAckPayloadSchema),
]);

export type AgentProtocolMessage = z.infer<typeof AgentProtocolMessageSchema>;
export type AgentMessageType = AgentProtocolMessage["type"];

// ==========================================
// Protocol Errors & Helpers
// ==========================================

export class AgentProtocolError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AgentProtocolError";
  }
}

export class UnsupportedProtocolVersionError extends AgentProtocolError {
  constructor(receivedVersion: unknown) {
    super(
      `Unsupported agent protocol version '${String(receivedVersion)}'. Expected '${AGENT_PROTOCOL_VERSION}'.`,
    );
    this.name = "UnsupportedProtocolVersionError";
  }
}

export class MalformedMessageError extends AgentProtocolError {
  readonly validationIssues: unknown;
  constructor(message: string, issues?: unknown) {
    super(message);
    this.name = "MalformedMessageError";
    this.validationIssues = issues;
  }
}

/**
 * Parses and validates an unknown input as an AgentProtocolMessage.
 * Rejects unsupported versions and malformed schemas with typed errors.
 */
export function parseAgentMessage(input: unknown): AgentProtocolMessage {
  if (typeof input !== "object" || input === null) {
    throw new MalformedMessageError(
      "Message payload must be a non-null object",
    );
  }

  const raw = input as Record<string, unknown>;

  if (raw.protocol !== AGENT_PROTOCOL_NAME) {
    throw new MalformedMessageError(
      `Invalid protocol '${String(raw.protocol)}'. Expected '${AGENT_PROTOCOL_NAME}'.`,
    );
  }

  if (
    typeof raw.protocolVersion !== "string" ||
    !isCompatibleAgentProtocolVersion(
      AGENT_PROTOCOL_VERSION,
      raw.protocolVersion,
    )
  ) {
    throw new UnsupportedProtocolVersionError(raw.protocolVersion);
  }

  const result = AgentProtocolMessageSchema.safeParse(input);
  if (!result.success) {
    throw new MalformedMessageError(
      `Malformed agent protocol message '${String(raw.type)}': ${result.error.message}`,
      result.error.issues,
    );
  }

  return result.data;
}

/**
 * Safely serializes an AgentProtocolMessage into JSON, enforcing maximum frame size bounds.
 */
export function serializeAgentMessage(message: AgentProtocolMessage): string {
  const serialized = JSON.stringify(message);
  if (Buffer.byteLength(serialized, "utf8") > MAX_MESSAGE_SIZE_BYTES) {
    throw new AgentProtocolError(
      `Message size exceeds maximum allowed size of ${MAX_MESSAGE_SIZE_BYTES} bytes`,
    );
  }
  return serialized;
}

/**
 * Checks if a message type belongs to assignment execution.
 */
export function isAssignmentMessageType(type: string): boolean {
  return type.startsWith("assignment.");
}

// ==========================================
// Reconnection Journal Reconciliation
// ==========================================

export interface AgentJournalEntry {
  readonly assignmentId: string;
  readonly attemptId: string;
  readonly idempotencyKey: string;
  readonly status: "running" | "completed" | "failed" | "cancelled";
  readonly terminalResult?: Record<string, unknown>;
  readonly updatedAt: string;
}

export interface CloudAssignmentRecord {
  readonly assignmentId: string;
  readonly attemptId: string;
  readonly idempotencyKey: string;
  readonly status: string;
}

export type JournalReconcileAction =
  | {
      action: "submit_result";
      assignmentId: string;
      terminalResult: Record<string, unknown>;
    }
  | { action: "cancel_orphaned"; assignmentId: string }
  | { action: "acknowledge_synced"; assignmentId: string }
  | { action: "rerun_lost"; assignmentId: string };

/**
 * Reconciles the local Agent assignment journal with authoritative Cloud assignment state after a reconnect.
 */
export function reconcileAssignmentJournal(
  cloudRecords: readonly CloudAssignmentRecord[],
  agentJournal: readonly AgentJournalEntry[],
): JournalReconcileAction[] {
  const cloudMap = new Map(cloudRecords.map((c) => [c.assignmentId, c]));
  const actions: JournalReconcileAction[] = [];

  for (const entry of agentJournal) {
    const cloudRecord = cloudMap.get(entry.assignmentId);

    if (!cloudRecord) {
      // Cloud no longer tracks this assignment (or cancelled while offline)
      actions.push({
        action: "cancel_orphaned",
        assignmentId: entry.assignmentId,
      });
      continue;
    }

    // Terminal result completed on agent during disconnect
    if (
      (entry.status === "completed" ||
        entry.status === "failed" ||
        entry.status === "cancelled") &&
      cloudRecord.status !== "completed" &&
      cloudRecord.status !== "failed" &&
      cloudRecord.status !== "cancelled"
    ) {
      actions.push({
        action: "submit_result",
        assignmentId: entry.assignmentId,
        terminalResult: entry.terminalResult ?? {},
      });
    } else {
      actions.push({
        action: "acknowledge_synced",
        assignmentId: entry.assignmentId,
      });
    }
  }

  return actions;
}
