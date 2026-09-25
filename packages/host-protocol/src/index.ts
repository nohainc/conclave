import { z } from "zod";
import {
  HOST_PROTOCOL_NAME,
  HOST_PROTOCOL_VERSION,
  HOST_PROTOCOL_MAX_MESSAGE_SIZE_BYTES,
  HOST_PROTOCOL_MESSAGE_TYPES,
  HOST_PROTOCOL_BASE_ENVELOPE_FIELDS,
  HOST_PROTOCOL_ASSIGNMENT_ENVELOPE_FIELDS,
  WORKER_PROTOCOL_NAME,
  WORKER_PROTOCOL_VERSION,
  WORKER_PROTOCOL_JSON_RPC_VERSION,
  WORKER_PROTOCOL_METHODS,
  WORKER_PROTOCOL_NOTIFICATIONS,
  AGENT_PROTOCOL_NAME,
  AGENT_PROTOCOL_VERSION,
  AGENT_PROTOCOL_MAX_MESSAGE_SIZE_BYTES,
  AGENT_PROTOCOL_MESSAGE_TYPES,
  AGENT_PROTOCOL_BASE_ENVELOPE_FIELDS,
  AGENT_PROTOCOL_ASSIGNMENT_ENVELOPE_FIELDS,
} from "./generated.js";
export * from "./workspace-runtime.js";

export {
  HOST_PROTOCOL_NAME,
  HOST_PROTOCOL_VERSION,
  HOST_PROTOCOL_MAX_MESSAGE_SIZE_BYTES,
  HOST_PROTOCOL_MESSAGE_TYPES,
  HOST_PROTOCOL_BASE_ENVELOPE_FIELDS,
  HOST_PROTOCOL_ASSIGNMENT_ENVELOPE_FIELDS,
  WORKER_PROTOCOL_NAME,
  WORKER_PROTOCOL_VERSION,
  WORKER_PROTOCOL_JSON_RPC_VERSION,
  WORKER_PROTOCOL_METHODS,
  WORKER_PROTOCOL_NOTIFICATIONS,
  AGENT_PROTOCOL_NAME,
  AGENT_PROTOCOL_VERSION,
  AGENT_PROTOCOL_MAX_MESSAGE_SIZE_BYTES,
  AGENT_PROTOCOL_MESSAGE_TYPES,
  AGENT_PROTOCOL_BASE_ENVELOPE_FIELDS,
  AGENT_PROTOCOL_ASSIGNMENT_ENVELOPE_FIELDS,
};

const protocolVersionPattern = /^\d+\.\d+(?:\.\d+)?$/;

function protocolVersionParts(version: string): [number, number] {
  if (!protocolVersionPattern.test(version)) {
    throw new Error(`Invalid protocol version: ${version}`);
  }
  const [major, minor] = version.split(".").map(Number);
  return [major ?? 0, minor ?? 0];
}

/**
 * Validates protocol version compatibility.
 * Major versions must match exactly; remote minor must be >= local minor.
 */
export function isCompatibleHostProtocolVersion(
  local: string,
  remote: string,
): boolean {
  const [localMajor, localMinor] = protocolVersionParts(local);
  const [remoteMajor, remoteMinor] = protocolVersionParts(remote);
  return localMajor === remoteMajor && remoteMinor >= localMinor;
}

export function isCompatibleAgentProtocolVersion(
  local: string,
  remote: string,
): boolean {
  return isCompatibleHostProtocolVersion(local, remote);
}

export const MAX_MESSAGE_SIZE_BYTES = HOST_PROTOCOL_MAX_MESSAGE_SIZE_BYTES;

const nonEmptyStr = z.string().trim().min(1);
const timestampStr = z.string().datetime();

// ============================================================================
// Host Protocol Envelopes & Types (Cloud <-> Host)
// ============================================================================

export const hostBaseEnvelopeFields = {
  protocol: z.literal(HOST_PROTOCOL_NAME),
  protocolVersion: z.string().regex(protocolVersionPattern),
  messageId: nonEmptyStr,
  correlationId: nonEmptyStr.optional(),
  timestamp: timestampStr,
};

export const hostAssignmentEnvelopeFields = {
  ...hostBaseEnvelopeFields,
  workspaceId: nonEmptyStr,
  hostId: nonEmptyStr,
  workerId: nonEmptyStr,
  runId: nonEmptyStr,
  taskId: nonEmptyStr,
  attemptId: nonEmptyStr,
  assignmentId: nonEmptyStr,
  idempotencyKey: nonEmptyStr,
};

// ── Host Lifecycle & Presence ───────────────────────────────────────────────

export const HostCapabilitiesSchema = z
  .object({
    os: z.enum(["macos", "linux", "windows"]),
    arch: z.enum(["arm64", "x64"]),
    version: nonEmptyStr,
    supportedRuntimes: z.array(nonEmptyStr),
    maxConcurrentWorkers: z.number().int().min(1),
    customCapabilities: z.array(nonEmptyStr).optional(),
  })
  .strict();
export type HostCapabilities = z.infer<typeof HostCapabilitiesSchema>;

export const HostHelloPayloadSchema = z
  .object({
    hostId: nonEmptyStr,
    name: nonEmptyStr,
    hostname: nonEmptyStr,
    hostVersion: nonEmptyStr,
    capabilities: HostCapabilitiesSchema,
    enrolledWorkspaces: z.array(nonEmptyStr).default([]),
    authCredentials: z.record(z.string(), z.string()).optional(),
  })
  .strict();
export type HostHelloPayload = z.infer<typeof HostHelloPayloadSchema>;

export const HostHelloAckPayloadSchema = z
  .object({
    hostId: nonEmptyStr,
    status: z.enum(["authenticated", "rejected"]),
    authenticatedAt: timestampStr,
    serverVersion: nonEmptyStr,
    sessionToken: nonEmptyStr.optional(),
    activeWorkspaceBindings: z.array(nonEmptyStr).default([]),
    rejectionReason: z.string().optional(),
  })
  .strict();
export type HostHelloAckPayload = z.infer<typeof HostHelloAckPayloadSchema>;

export const HostHeartbeatPayloadSchema = z
  .object({
    hostId: nonEmptyStr,
    timestamp: timestampStr,
    metrics: z
      .object({
        cpuUsagePercent: z.number().min(0).max(100).optional(),
        memoryUsageBytes: z.number().int().min(0).optional(),
        activeWorkers: z.number().int().min(0).optional(),
        pendingAssignments: z.number().int().min(0).optional(),
      })
      .optional(),
  })
  .strict();
export type HostHeartbeatPayload = z.infer<typeof HostHeartbeatPayloadSchema>;

export const HostHeartbeatAckPayloadSchema = z
  .object({
    hostId: nonEmptyStr,
    acknowledgedAt: timestampStr,
    serverTime: timestampStr,
    nextHeartbeatIntervalMs: z.number().int().min(1000).default(30000),
  })
  .strict();
export type HostHeartbeatAckPayload = z.infer<
  typeof HostHeartbeatAckPayloadSchema
>;

export const HostSyncRequestPayloadSchema = z
  .object({
    hostId: nonEmptyStr,
    syncToken: z.string().optional(),
    knownAssignmentIds: z.array(nonEmptyStr).default([]),
    knownWorkerIds: z.array(nonEmptyStr).default([]),
  })
  .strict();
export type HostSyncRequestPayload = z.infer<
  typeof HostSyncRequestPayloadSchema
>;

export const HostSyncResultPayloadSchema = z
  .object({
    hostId: nonEmptyStr,
    syncToken: nonEmptyStr,
    pendingAssignments: z.array(nonEmptyStr).default([]),
    installedWorkers: z.array(nonEmptyStr).default([]),
    credentialStatuses: z.record(z.string(), z.string()).default({}),
  })
  .strict();
export type HostSyncResultPayload = z.infer<typeof HostSyncResultPayloadSchema>;

export const HostStatusPayloadSchema = z
  .object({
    hostId: nonEmptyStr,
    status: z.enum(["online", "draining", "offline"]),
    activeAssignmentsCount: z.number().int().min(0).default(0),
    reason: z.string().optional(),
  })
  .strict();
export type HostStatusPayload = z.infer<typeof HostStatusPayloadSchema>;

export const HostUpdatePayloadSchema = z
  .object({
    hostId: nonEmptyStr,
    targetVersion: nonEmptyStr,
    packageDigest: nonEmptyStr,
    packageR2Key: nonEmptyStr,
    signature: nonEmptyStr,
    channel: z.enum(["stable", "beta", "development"]).default("stable"),
  })
  .strict();
export type HostUpdatePayload = z.infer<typeof HostUpdatePayloadSchema>;

// ── Worker Management over Host Protocol ────────────────────────────────────

export const WorkerInstallPayloadSchema = z
  .object({
    hostId: nonEmptyStr,
    workerId: nonEmptyStr,
    version: nonEmptyStr,
    packageDigest: nonEmptyStr,
    packageR2Key: nonEmptyStr,
    signature: nonEmptyStr,
    entrypoint: nonEmptyStr,
    permissions: z.array(nonEmptyStr).default([]),
  })
  .strict();
export type WorkerInstallPayload = z.infer<typeof WorkerInstallPayloadSchema>;

export const WorkerRemovePayloadSchema = z
  .object({
    hostId: nonEmptyStr,
    workerId: nonEmptyStr,
    version: nonEmptyStr.optional(),
    purgeData: z.boolean().default(false),
  })
  .strict();
export type WorkerRemovePayload = z.infer<typeof WorkerRemovePayloadSchema>;

export const WorkerStatusPayloadSchema = z
  .object({
    hostId: nonEmptyStr,
    workerId: nonEmptyStr,
    version: nonEmptyStr,
    status: z.enum([
      "absent",
      "requested",
      "downloading",
      "verifying",
      "installing",
      "ready",
      "updating",
      "degraded",
      "failed",
      "removing",
    ]),
    error: z.string().optional(),
    packageStatus: z
      .enum(["absent", "installing", "ready", "updating", "failed"])
      .optional(),
    credentialStatus: z
      .enum(["unknown", "setup_required", "ready", "expired", "error"])
      .optional(),
    permissionsStatus: z
      .enum(["unknown", "checking", "ready", "denied", "error"])
      .optional(),
    effectiveReadiness: z
      .enum([
        "unknown",
        "setup_required",
        "ready",
        "degraded",
        "failed",
        "revoked",
      ])
      .optional(),
    activeAssignmentCount: z.number().int().nonnegative().optional(),
    workerTypeId: nonEmptyStr.optional(),
  })
  .strict();
export type WorkerStatusPayload = z.infer<typeof WorkerStatusPayloadSchema>;

// ── Credential Status ───────────────────────────────────────────────────────

export const CredentialStatusPayloadSchema = z
  .object({
    hostId: nonEmptyStr,
    credentialProfileId: nonEmptyStr,
    workerId: nonEmptyStr,
    status: z.enum(["ready", "needs_auth", "invalid", "expired"]),
    authMode: z.enum([
      "none",
      "api_key",
      "oauth_browser",
      "local_cli_session",
      "interactive_custom",
    ]),
    visibility: z.enum(["private", "workspace"]).default("private"),
    lastCheckedAt: timestampStr,
    errorMessage: z.string().optional(),
  })
  .strict();
export type CredentialStatusPayload = z.infer<
  typeof CredentialStatusPayloadSchema
>;

// ── Assignment Snapshot & Execution Protocol ────────────────────────────────

/**
 * Assignment snapshot: completely describes execution target and context.
 *
 * Secret Rule: Uses opaque credentialProfileId reference. Long-lived raw
 * secrets are never transmitted.
 */
export const AssignmentSnapshotSchema = z
  .object({
    assignmentId: nonEmptyStr,
    workstreamId: nonEmptyStr.optional(),
    workRequestId: nonEmptyStr.optional(),
    /** Historical compatibility field; active runtime uses Workstream IDs. */
    checkoutId: nonEmptyStr.optional(),
    leaseId: nonEmptyStr.optional(),
    fencingToken: z.number().int().positive().optional(),
    expectedRevision: nonEmptyStr.optional(),
    executionClass: z
      .enum(["stateless_read", "stateful_workstream"])
      .optional(),
    workspaceId: nonEmptyStr,
    projectId: nonEmptyStr,
    runId: nonEmptyStr,
    taskId: nonEmptyStr,
    attemptId: nonEmptyStr,
    requestedByUserId: nonEmptyStr,
    hostId: nonEmptyStr,
    workerId: nonEmptyStr,
    configuredWorkerId: nonEmptyStr.optional(),
    workerTypeId: nonEmptyStr.optional(),
    resolvedWorkerVersion: nonEmptyStr,
    credentialProfileId: nonEmptyStr.optional(),
    model: z.string().optional(),
    config: z.record(z.string(), z.unknown()).default({}),
    sessionPolicy: z
      .enum([
        "stateless",
        "isolated_workspace",
        "reuse_session",
        "persistent_context",
      ])
      .default("stateless"),
    permissions: z.array(nonEmptyStr).default([]),
    contextRefs: z.array(z.record(z.string(), z.unknown())).default([]),
    timeoutMs: z.number().int().min(1000).default(60000),
    idempotencyKey: nonEmptyStr,
  })
  .strict();
export type AssignmentSnapshot = z.infer<typeof AssignmentSnapshotSchema>;

export const V4AssignmentStartPayloadSchema = z
  .object({
    snapshot: AssignmentSnapshotSchema,
    input: z.record(z.string(), z.unknown()),
  })
  .strict();
export type V4AssignmentStartPayload = z.infer<
  typeof V4AssignmentStartPayloadSchema
>;

export const HostAssignmentAckPayloadSchema = z
  .object({
    assignmentId: nonEmptyStr,
    hostId: nonEmptyStr,
    workerId: nonEmptyStr,
    status: z.enum(["accepted", "rejected"]),
    acknowledgedAt: timestampStr,
    rejectionReason: z.string().optional(),
  })
  .strict();
export type HostAssignmentAckPayload = z.infer<
  typeof HostAssignmentAckPayloadSchema
>;

export const HostAssignmentProgressPayloadSchema = z
  .object({
    assignmentId: nonEmptyStr,
    percentage: z.number().min(0).max(100),
    message: z.string().default(""),
    observedAt: timestampStr,
    metrics: z.record(z.string(), z.unknown()).optional(),
  })
  .strict();
export type HostAssignmentProgressPayload = z.infer<
  typeof HostAssignmentProgressPayloadSchema
>;

export const HostAssignmentResultPayloadSchema = z
  .object({
    assignmentId: nonEmptyStr,
    status: z.enum(["completed", "failed", "cancelled"]),
    output: z.record(z.string(), z.unknown()).nullable(),
    findings: z.array(z.unknown()).default([]),
    artifactIds: z.array(nonEmptyStr).default([]),
    evidence: z
      .object({
        observedAt: timestampStr,
        metrics: z.record(z.string(), z.unknown()).optional(),
        logs: z.array(z.string()).optional(),
      })
      .optional(),
    completedAt: timestampStr,
  })
  .strict();
export type HostAssignmentResultPayload = z.infer<
  typeof HostAssignmentResultPayloadSchema
>;

export const HostAssignmentErrorPayloadSchema = z
  .object({
    assignmentId: nonEmptyStr,
    error: z
      .object({
        code: nonEmptyStr,
        message: nonEmptyStr,
        retryable: z.boolean().default(false),
        details: z.record(z.string(), z.unknown()).optional(),
      })
      .strict(),
    failedAt: timestampStr,
  })
  .strict();
export type HostAssignmentErrorPayload = z.infer<
  typeof HostAssignmentErrorPayloadSchema
>;

export const HostAssignmentCancelPayloadSchema = z
  .object({
    assignmentId: nonEmptyStr,
    reason: z.string().default("User or Cloud requested cancellation"),
    deadlineMs: z.number().int().min(0).optional(),
  })
  .strict();
export type HostAssignmentCancelPayload = z.infer<
  typeof HostAssignmentCancelPayloadSchema
>;

export const HostAssignmentCancelAckPayloadSchema = z
  .object({
    assignmentId: nonEmptyStr,
    cancelled: z.boolean(),
    reason: z.string().optional(),
  })
  .strict();
export type HostAssignmentCancelAckPayload = z.infer<
  typeof HostAssignmentCancelAckPayloadSchema
>;

export const AssignmentStartPayloadSchema = V4AssignmentStartPayloadSchema;
export type AssignmentStartPayload = V4AssignmentStartPayload;
export const AssignmentAckPayloadSchema = HostAssignmentAckPayloadSchema;
export type AssignmentAckPayload = HostAssignmentAckPayload;
export const AssignmentProgressPayloadSchema =
  HostAssignmentProgressPayloadSchema;
export type AssignmentProgressPayload = HostAssignmentProgressPayload;
export const AssignmentResultPayloadSchema = HostAssignmentResultPayloadSchema;
export type AssignmentResultPayload = HostAssignmentResultPayload;
export const AssignmentErrorPayloadSchema = HostAssignmentErrorPayloadSchema;
export type AssignmentErrorPayload = HostAssignmentErrorPayload;
export const AssignmentCancelPayloadSchema = HostAssignmentCancelPayloadSchema;
export type AssignmentCancelPayload = HostAssignmentCancelPayload;
export const AssignmentCancelAckPayloadSchema =
  HostAssignmentCancelAckPayloadSchema;
export type AssignmentCancelAckPayload = HostAssignmentCancelAckPayload;

// ── Discriminated Union of Host Protocol Messages ───────────────────────────

const hostMessage = <TType extends string, TPayload extends z.ZodType>(
  type: TType,
  payloadSchema: TPayload,
) =>
  z
    .object({
      ...hostBaseEnvelopeFields,
      type: z.literal(type),
      payload: payloadSchema,
    })
    .strict();

const hostAssignmentMessage = <
  TType extends string,
  TPayload extends z.ZodType,
>(
  type: TType,
  payloadSchema: TPayload,
) =>
  z
    .object({
      ...hostAssignmentEnvelopeFields,
      type: z.literal(type),
      payload: payloadSchema,
    })
    .strict();

export const HostProtocolMessageSchema = z.discriminatedUnion("type", [
  // Host presence & lifecycle
  hostMessage("host.hello", HostHelloPayloadSchema),
  hostMessage("host.hello.ack", HostHelloAckPayloadSchema),
  hostMessage("host.heartbeat", HostHeartbeatPayloadSchema),
  hostMessage("host.heartbeat.ack", HostHeartbeatAckPayloadSchema),
  hostMessage("host.sync.request", HostSyncRequestPayloadSchema),
  hostMessage("host.sync.result", HostSyncResultPayloadSchema),
  hostMessage("host.status", HostStatusPayloadSchema),
  hostMessage("host.update", HostUpdatePayloadSchema),

  // Worker installation & status
  hostMessage("worker.install", WorkerInstallPayloadSchema),
  hostMessage("worker.remove", WorkerRemovePayloadSchema),
  hostMessage("worker.status", WorkerStatusPayloadSchema),

  // Credential status
  hostMessage("credential.status", CredentialStatusPayloadSchema),

  // Assignment lifecycle
  hostAssignmentMessage("assignment.start", V4AssignmentStartPayloadSchema),
  hostAssignmentMessage("assignment.ack", HostAssignmentAckPayloadSchema),
  hostAssignmentMessage(
    "assignment.progress",
    HostAssignmentProgressPayloadSchema,
  ),
  hostAssignmentMessage("assignment.result", HostAssignmentResultPayloadSchema),
  hostAssignmentMessage("assignment.error", HostAssignmentErrorPayloadSchema),
  hostAssignmentMessage("assignment.cancel", HostAssignmentCancelPayloadSchema),
  hostAssignmentMessage(
    "assignment.cancel.ack",
    HostAssignmentCancelAckPayloadSchema,
  ),
]);
export type HostProtocolMessage = z.infer<typeof HostProtocolMessageSchema>;
export type HostMessageType = HostProtocolMessage["type"];

// ============================================================================
// Worker Protocol (Host <-> Worker JSON-RPC 2.0)
// ============================================================================

export const WorkerInitializeParamsSchema = z
  .object({
    workerId: nonEmptyStr,
    version: nonEmptyStr,
    protocolVersion: nonEmptyStr.default("4.0"),
    hostVersion: nonEmptyStr,
    config: z.record(z.string(), z.unknown()).default({}),
    permissions: z.array(nonEmptyStr).default([]),
  })
  .strict();
export type WorkerInitializeParams = z.infer<
  typeof WorkerInitializeParamsSchema
>;

export const WorkerHealthResultSchema = z
  .object({
    status: z.enum(["healthy", "degraded", "unhealthy"]),
    details: z.record(z.string(), z.unknown()).optional(),
  })
  .strict();
export type WorkerHealthResult = z.infer<typeof WorkerHealthResultSchema>;

export const WorkerDescribeResultSchema = z
  .object({
    workerId: nonEmptyStr,
    displayName: nonEmptyStr,
    version: nonEmptyStr,
    roles: z.array(nonEmptyStr).min(1),
    capabilities: z.array(nonEmptyStr).min(1),
    permissions: z.array(nonEmptyStr).default([]),
    sessionModes: z
      .array(
        z.enum([
          "stateless",
          "isolated_workspace",
          "reuse_session",
          "persistent_context",
        ]),
      )
      .default(["stateless"]),
    concurrencyModel: z
      .object({
        maxConcurrentAssignments: z.number().int().min(1).default(1),
        persistentRuntime: z.boolean().default(false),
        isolation: z.enum(["process", "thread", "shared"]).default("process"),
      })
      .default({
        maxConcurrentAssignments: 1,
        persistentRuntime: false,
        isolation: "process",
      }),
    credentialRequirements: z
      .array(z.record(z.string(), z.unknown()))
      .default([]),
  })
  .strict();
export type WorkerDescribeResult = z.infer<typeof WorkerDescribeResultSchema>;

export const WorkerExecuteParamsSchema = z
  .object({
    assignment: AssignmentSnapshotSchema,
    input: z.record(z.string(), z.unknown()),
  })
  .strict();
export type WorkerExecuteParams = z.infer<typeof WorkerExecuteParamsSchema>;

export const WorkerProgressNotificationSchema = z
  .object({
    assignmentId: nonEmptyStr,
    percentage: z.number().min(0).max(100),
    message: z.string().default(""),
    timestamp: timestampStr,
  })
  .strict();
export type WorkerProgressNotification = z.infer<
  typeof WorkerProgressNotificationSchema
>;

export const WorkerUsageNotificationSchema = z
  .object({
    assignmentId: nonEmptyStr,
    tokensUsed: z.number().int().min(0).optional(),
    estimatedCostMicros: z.number().int().min(0).optional(),
    timestamp: timestampStr,
  })
  .strict();
export type WorkerUsageNotification = z.infer<
  typeof WorkerUsageNotificationSchema
>;

export const WorkerStatusNotificationSchema = z
  .object({
    assignmentId: nonEmptyStr,
    status: nonEmptyStr,
    message: z.string().max(8192).optional(),
    timestamp: timestampStr,
  })
  .strict();
export type WorkerStatusNotification = z.infer<
  typeof WorkerStatusNotificationSchema
>;

export const WorkerOutputDeltaNotificationSchema = z
  .object({
    assignmentId: nonEmptyStr,
    delta: z.string().max(8192),
    sequence: z.number().int().min(0).optional(),
    timestamp: timestampStr,
  })
  .strict();
export type WorkerOutputDeltaNotification = z.infer<
  typeof WorkerOutputDeltaNotificationSchema
>;

export const WorkerToolStartedNotificationSchema = z
  .object({
    assignmentId: nonEmptyStr,
    toolCallId: nonEmptyStr,
    tool: nonEmptyStr,
    timestamp: timestampStr,
  })
  .strict();
export type WorkerToolStartedNotification = z.infer<
  typeof WorkerToolStartedNotificationSchema
>;

export const WorkerToolCompletedNotificationSchema = z
  .object({
    assignmentId: nonEmptyStr,
    toolCallId: nonEmptyStr,
    tool: nonEmptyStr,
    success: z.boolean(),
    timestamp: timestampStr,
  })
  .strict();
export type WorkerToolCompletedNotification = z.infer<
  typeof WorkerToolCompletedNotificationSchema
>;

export const WorkerArtifactNotificationSchema = z
  .object({
    assignmentId: nonEmptyStr,
    artifactId: nonEmptyStr,
    name: nonEmptyStr,
    type: nonEmptyStr,
    digest: nonEmptyStr,
    contentBase64: z.string().optional(),
    metadata: z.record(z.string(), z.unknown()).default({}),
  })
  .strict();
export type WorkerArtifactNotification = z.infer<
  typeof WorkerArtifactNotificationSchema
>;

export const WorkerResultNotificationSchema = z
  .object({
    assignmentId: nonEmptyStr,
    status: z.enum(["completed", "failed", "cancelled"]),
    output: z.record(z.string(), z.unknown()).nullable(),
    findings: z.array(z.unknown()).default([]),
    artifactIds: z.array(nonEmptyStr).default([]),
    completedAt: timestampStr,
  })
  .strict();
export type WorkerResultNotification = z.infer<
  typeof WorkerResultNotificationSchema
>;

export const WorkerErrorNotificationSchema = z
  .object({
    assignmentId: nonEmptyStr,
    code: nonEmptyStr,
    message: nonEmptyStr,
    retryable: z.boolean().default(false),
    details: z.record(z.string(), z.unknown()).optional(),
    timestamp: timestampStr,
  })
  .strict();
export type WorkerErrorNotification = z.infer<
  typeof WorkerErrorNotificationSchema
>;

export const WorkerLogNotificationSchema = z
  .object({
    assignmentId: nonEmptyStr.optional(),
    level: z.enum(["debug", "info", "warn", "error"]),
    message: nonEmptyStr,
    timestamp: timestampStr,
    metadata: z.record(z.string(), z.unknown()).default({}),
  })
  .strict();
export type WorkerLogNotification = z.infer<typeof WorkerLogNotificationSchema>;

export const WorkerCancelParamsSchema = z
  .object({
    assignmentId: nonEmptyStr,
    reason: z.string().optional(),
  })
  .strict();
export type WorkerCancelParams = z.infer<typeof WorkerCancelParamsSchema>;

export const WorkerShutdownParamsSchema = z
  .object({
    gracePeriodMs: z.number().int().min(0).default(5000),
  })
  .strict();
export type WorkerShutdownParams = z.infer<typeof WorkerShutdownParamsSchema>;

const workerRequestParamsSchemas = {
  initialize: WorkerInitializeParamsSchema,
  health: z.object({}).strict(),
  describe: z.object({}).strict(),
  execute: WorkerExecuteParamsSchema,
  cancel: WorkerCancelParamsSchema,
  shutdown: WorkerShutdownParamsSchema,
} as const;

export const JsonRpcRequestSchema = z
  .object({
    jsonrpc: z.literal("2.0"),
    id: z.union([z.string(), z.number()]),
    method: z.enum(WORKER_PROTOCOL_METHODS),
    params: z.record(z.string(), z.unknown()).default({}),
  })
  .strict();
export type JsonRpcRequest = z.infer<typeof JsonRpcRequestSchema>;

export const JsonRpcNotificationSchema = z
  .object({
    jsonrpc: z.literal("2.0"),
    method: z.enum(WORKER_PROTOCOL_NOTIFICATIONS),
    params: z.record(z.string(), z.unknown()).default({}),
  })
  .strict();
export type JsonRpcNotification = z.infer<typeof JsonRpcNotificationSchema>;

const workerNotificationParamsSchemas = {
  progress: WorkerProgressNotificationSchema,
  status: WorkerStatusNotificationSchema,
  output_delta: WorkerOutputDeltaNotificationSchema,
  "tool.started": WorkerToolStartedNotificationSchema,
  "tool.completed": WorkerToolCompletedNotificationSchema,
  usage: WorkerUsageNotificationSchema,
  artifact: WorkerArtifactNotificationSchema,
  result: WorkerResultNotificationSchema,
  error: WorkerErrorNotificationSchema,
  log: WorkerLogNotificationSchema,
} as const;

// ============================================================================
// Errors & Parsers
// ============================================================================

export class ProtocolError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ProtocolError";
  }
}

export class UnsupportedHostProtocolVersionError extends ProtocolError {
  constructor(receivedVersion: unknown) {
    super(
      `Unsupported host protocol version '${String(receivedVersion)}'. Expected '${HOST_PROTOCOL_VERSION}'.`,
    );
    this.name = "UnsupportedHostProtocolVersionError";
  }
}

export class MalformedProtocolMessageError extends ProtocolError {
  readonly validationIssues: unknown;
  constructor(message: string, issues?: unknown) {
    super(message);
    this.name = "MalformedProtocolMessageError";
    this.validationIssues = issues;
  }
}

/**
 * Parses and validates an unknown input as a HostProtocolMessage.
 */
export function parseHostMessage(input: unknown): HostProtocolMessage {
  if (typeof input !== "object" || input === null) {
    throw new MalformedProtocolMessageError(
      "Message payload must be a non-null object",
    );
  }

  const raw = input as Record<string, unknown>;

  if (raw.protocol !== HOST_PROTOCOL_NAME) {
    throw new MalformedProtocolMessageError(
      `Invalid protocol '${String(raw.protocol)}'. Expected '${HOST_PROTOCOL_NAME}'.`,
    );
  }

  if (
    typeof raw.protocolVersion !== "string" ||
    !isCompatibleHostProtocolVersion(HOST_PROTOCOL_VERSION, raw.protocolVersion)
  ) {
    throw new UnsupportedHostProtocolVersionError(raw.protocolVersion);
  }

  const result = HostProtocolMessageSchema.safeParse(input);
  if (!result.success) {
    throw new MalformedProtocolMessageError(
      `Malformed host protocol message '${String(raw.type)}': ${result.error.message}`,
      result.error.issues,
    );
  }

  if (isAssignmentMessageType(result.data.type)) {
    const payload = result.data.payload as Record<string, unknown>;
    const envelope = result.data as unknown as Record<string, unknown>;
    if (
      "snapshot" in payload &&
      payload.snapshot &&
      typeof payload.snapshot === "object" &&
      (payload.snapshot as Record<string, unknown>).idempotencyKey !==
        envelope.idempotencyKey
    ) {
      throw new MalformedProtocolMessageError(
        "Assignment envelope and snapshot idempotency keys must match",
      );
    }
  }

  return result.data;
}

/**
 * Parses a JSON-RPC message for Host <-> Worker interaction.
 */
export function parseWorkerRpcMessage(
  input: unknown,
): JsonRpcRequest | JsonRpcNotification {
  if (typeof input !== "object" || input === null) {
    throw new MalformedProtocolMessageError(
      "Worker RPC payload must be a non-null object",
    );
  }

  const raw = input as Record<string, unknown>;
  if (raw.jsonrpc !== "2.0") {
    throw new MalformedProtocolMessageError(
      `Invalid JSON-RPC version '${String(raw.jsonrpc)}'. Expected '2.0'.`,
    );
  }

  if ("id" in raw && raw.id !== undefined && raw.id !== null) {
    const res = JsonRpcRequestSchema.safeParse(input);
    if (!res.success) {
      throw new MalformedProtocolMessageError(
        `Invalid Worker JSON-RPC request '${String(raw.method)}': ${res.error.message}`,
        res.error.issues,
      );
    }
    const paramsSchema = workerRequestParamsSchemas[res.data.method];
    const params = paramsSchema.safeParse(res.data.params);
    if (!params.success) {
      throw new MalformedProtocolMessageError(
        `Invalid Worker JSON-RPC request '${String(raw.method)}': ${params.error.message}`,
        params.error.issues,
      );
    }
    return { ...res.data, params: params.data } as JsonRpcRequest;
  }

  const notif = JsonRpcNotificationSchema.safeParse(input);
  if (!notif.success) {
    throw new MalformedProtocolMessageError(
      `Invalid Worker JSON-RPC notification '${String(raw.method)}': ${notif.error.message}`,
      notif.error.issues,
    );
  }
  const paramsSchema = workerNotificationParamsSchemas[notif.data.method];
  const params = paramsSchema.safeParse(notif.data.params);
  if (!params.success) {
    throw new MalformedProtocolMessageError(
      `Invalid Worker JSON-RPC notification '${String(raw.method)}': ${params.error.message}`,
      params.error.issues,
    );
  }
  return { ...notif.data, params: params.data } as JsonRpcNotification;
}

// ============================================================================
// Legacy v3 Agent Protocol Definitions (for Coexistence During Migration)
// ============================================================================

export const baseEnvelopeFields = {
  protocol: z.literal(AGENT_PROTOCOL_NAME),
  protocolVersion: z.string().regex(protocolVersionPattern),
  messageId: nonEmptyStr,
  correlationId: nonEmptyStr.optional(),
  timestamp: timestampStr,
};

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

export const LegacyHostCapabilitiesSchema = z
  .object({
    os: z.enum(["macos", "linux", "windows"]),
    arch: z.enum(["arm64", "x64"]),
    agentVersion: nonEmptyStr,
    supportedRuntimes: z.array(nonEmptyStr),
    maxConcurrentWorkers: z.number().int().min(1),
    customCapabilities: z.array(nonEmptyStr).optional(),
  })
  .strict();
export type LegacyHostCapabilities = z.infer<
  typeof LegacyHostCapabilitiesSchema
>;

export const AgentHelloPayloadSchema = z
  .object({
    agentId: nonEmptyStr,
    workspaceId: nonEmptyStr,
    name: nonEmptyStr,
    hostname: nonEmptyStr,
    agentVersion: nonEmptyStr,
    capabilities: LegacyHostCapabilitiesSchema,
    authCredentials: z.record(z.string(), z.string()).optional(),
  })
  .strict();
export type AgentHelloPayload = z.infer<typeof AgentHelloPayloadSchema>;

export const AgentHelloAckPayloadSchema = z
  .object({
    agentId: nonEmptyStr,
    status: z.enum(["authenticated", "rejected"]),
    authenticatedAt: timestampStr,
    serverVersion: nonEmptyStr,
    sessionToken: nonEmptyStr.optional(),
    activeWorkspaceBindings: z.array(nonEmptyStr).optional(),
    rejectionReason: z.string().optional(),
  })
  .strict();
export type AgentHelloAckPayload = z.infer<typeof AgentHelloAckPayloadSchema>;

export const AgentHeartbeatPayloadSchema = z
  .object({
    agentId: nonEmptyStr,
    workspaceId: nonEmptyStr,
    sessionId: nonEmptyStr,
    status: z.enum(["online", "draining", "offline"]),
    activeWorkers: z.number().int().min(0),
    activeAssignments: z.number().int().min(0),
  })
  .strict();
export type AgentHeartbeatPayload = z.infer<typeof AgentHeartbeatPayloadSchema>;

export const AgentHeartbeatAckPayloadSchema = z
  .object({
    acknowledgedAt: timestampStr,
    serverTime: timestampStr,
    nextHeartbeatIntervalMs: z.number().int().min(1000).default(30000),
  })
  .strict();
export type AgentHeartbeatAckPayload = z.infer<
  typeof AgentHeartbeatAckPayloadSchema
>;

export const AgentSyncRequestPayloadSchema = z
  .object({
    agentId: nonEmptyStr,
    workspaceId: nonEmptyStr,
    syncToken: z.string().optional(),
    activeAssignmentIds: z.array(nonEmptyStr).default([]),
  })
  .strict();
export type AgentSyncRequestPayload = z.infer<
  typeof AgentSyncRequestPayloadSchema
>;

export const AgentSyncResponsePayloadSchema = z
  .object({
    syncToken: nonEmptyStr,
    pendingAssignments: z.array(nonEmptyStr).default([]),
    installedPluginIds: z.array(nonEmptyStr).default([]),
  })
  .strict();
export type AgentSyncResponsePayload = z.infer<
  typeof AgentSyncResponsePayloadSchema
>;

export const AgentUpdateAvailablePayloadSchema = z
  .object({
    version: nonEmptyStr,
    channel: z.enum(["stable", "beta", "development"]).default("stable"),
    packageR2Key: nonEmptyStr,
    packageDigest: nonEmptyStr,
    signature: nonEmptyStr,
    releaseNotes: z.string().optional(),
  })
  .strict();
export type AgentUpdateAvailablePayload = z.infer<
  typeof AgentUpdateAvailablePayloadSchema
>;

export const AgentUpdateStatusPayloadSchema = z
  .object({
    fromVersion: nonEmptyStr,
    targetVersion: nonEmptyStr,
    status: z.enum(["downloading", "applying", "verifying", "failed"]),
    error: z.string().optional(),
  })
  .strict();
export type AgentUpdateStatusPayload = z.infer<
  typeof AgentUpdateStatusPayloadSchema
>;

export const PluginInstallPayloadSchema = z
  .object({
    workerCatalogId: nonEmptyStr,
    version: nonEmptyStr,
    packageR2Key: nonEmptyStr,
    packageDigest: nonEmptyStr,
    signature: nonEmptyStr,
    entrypoint: nonEmptyStr,
    permissions: z.array(nonEmptyStr).default([]),
    secretSchema: z.record(z.string(), z.unknown()).default({}),
  })
  .strict();
export type PluginInstallPayload = z.infer<typeof PluginInstallPayloadSchema>;

export const PluginUpdatePayloadSchema = z
  .object({
    workerCatalogId: nonEmptyStr,
    fromVersion: nonEmptyStr,
    targetVersion: nonEmptyStr,
    packageR2Key: nonEmptyStr,
    packageDigest: nonEmptyStr,
    signature: nonEmptyStr,
  })
  .strict();
export type PluginUpdatePayload = z.infer<typeof PluginUpdatePayloadSchema>;

export const PluginRemovePayloadSchema = z
  .object({
    workerCatalogId: nonEmptyStr,
    version: nonEmptyStr.optional(),
    purgeData: z.boolean().default(false),
  })
  .strict();
export type PluginRemovePayload = z.infer<typeof PluginRemovePayloadSchema>;

export const PluginStatusPayloadSchema = z
  .object({
    workerCatalogId: nonEmptyStr,
    version: nonEmptyStr,
    status: z.enum(["installed", "installing", "failed", "removed"]),
    error: z.string().optional(),
  })
  .strict();
export type PluginStatusPayload = z.infer<typeof PluginStatusPayloadSchema>;

export const WorkerConfigurePayloadSchema = z
  .object({
    workerId: nonEmptyStr,
    workerCatalogId: nonEmptyStr,
    configuration: z.record(z.string(), z.unknown()).default({}),
    secrets: z.record(z.string(), z.string()).default({}),
  })
  .strict();
export type WorkerConfigurePayload = z.infer<
  typeof WorkerConfigurePayloadSchema
>;

const WorkerStatusRecordSchema = z
  .object({
    workerId: nonEmptyStr,
    hostId: nonEmptyStr.optional(),
    version: nonEmptyStr.optional(),
    status: z.enum([
      "absent",
      "requested",
      "downloading",
      "verifying",
      "installing",
      "ready",
      "updating",
      "degraded",
      "failed",
      "removing",
      "busy",
      "error",
      "unconfigured",
    ]),
    activeAssignmentCount: z.number().int().min(0).default(0),
    error: z.string().optional(),
    installedAt: z.string().optional(),
  })
  .strict();
export const WorkerStatusLegacyPayloadSchema = z.union([
  WorkerStatusRecordSchema,
  z
    .object({
      workers: z.array(WorkerStatusRecordSchema),
    })
    .strict(),
]);
export type WorkerStatusLegacyPayload = z.infer<
  typeof WorkerStatusLegacyPayloadSchema
>;

export const LegacyAssignmentStartPayloadSchema = z
  .object({
    input: z.record(z.string(), z.unknown()),
    timeoutMs: z.number().int().min(1000).default(60000),
    contextArtifacts: z.array(z.record(z.string(), z.unknown())).default([]),
    credentials: z.record(z.string(), z.string()).optional(),
  })
  .strict();
export type LegacyAssignmentStartPayload = z.infer<
  typeof LegacyAssignmentStartPayloadSchema
>;

export const LegacyAssignmentAckPayloadSchema = z
  .object({
    status: z.enum(["accepted", "rejected"]),
    acknowledgedAt: timestampStr,
    rejectionReason: z.string().optional(),
  })
  .strict();
export type LegacyAssignmentAckPayload = z.infer<
  typeof LegacyAssignmentAckPayloadSchema
>;

export const LegacyAssignmentProgressPayloadSchema = z
  .object({
    percentage: z.number().min(0).max(100),
    message: z.string().default(""),
    observedAt: timestampStr,
    metrics: z.record(z.string(), z.unknown()).optional(),
  })
  .strict();
export type LegacyAssignmentProgressPayload = z.infer<
  typeof LegacyAssignmentProgressPayloadSchema
>;

export const LegacyAssignmentResultPayloadSchema = z
  .object({
    status: z.enum(["succeeded", "failed", "cancelled"]),
    summary: nonEmptyStr,
    output: z.record(z.string(), z.unknown()).default({}),
    findings: z.array(z.unknown()).default([]),
    artifactIds: z.array(nonEmptyStr).default([]),
    completedAt: timestampStr,
  })
  .strict();
export type LegacyAssignmentResultPayload = z.infer<
  typeof LegacyAssignmentResultPayloadSchema
>;

export const AssignmentFailurePayloadSchema = z
  .object({
    error: z
      .object({
        code: nonEmptyStr,
        message: nonEmptyStr,
        retryable: z.boolean().default(false),
        details: z.record(z.string(), z.unknown()).optional(),
      })
      .strict(),
    failedAt: timestampStr,
  })
  .strict();
export type AssignmentFailurePayload = z.infer<
  typeof AssignmentFailurePayloadSchema
>;

export const AssignmentCancelledPayloadSchema = z
  .object({
    reason: z.string().default("Cancelled by agent host"),
    cancelledAt: timestampStr,
  })
  .strict();
export type AssignmentCancelledPayload = z.infer<
  typeof AssignmentCancelledPayloadSchema
>;

export const LegacyAssignmentCancelPayloadSchema = z
  .object({
    reason: nonEmptyStr,
    gracePeriodMs: z.number().int().min(0).default(5000),
  })
  .strict();
export type LegacyAssignmentCancelPayload = z.infer<
  typeof LegacyAssignmentCancelPayloadSchema
>;

export const LegacyAssignmentCancelAckPayloadSchema = z
  .object({
    cancelled: z.boolean(),
    alreadyTerminated: z.boolean().default(false),
  })
  .strict();
export type LegacyAssignmentCancelAckPayload = z.infer<
  typeof LegacyAssignmentCancelAckPayloadSchema
>;

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
  agentMessage("agent.capabilities", LegacyHostCapabilitiesSchema),
  agentMessage("agent.update.available", AgentUpdateAvailablePayloadSchema),
  agentMessage("agent.update.status", AgentUpdateStatusPayloadSchema),

  // Plugins
  agentMessage("plugin.install", PluginInstallPayloadSchema),
  agentMessage("plugin.update", PluginUpdatePayloadSchema),
  agentMessage("plugin.remove", PluginRemovePayloadSchema),
  agentMessage("plugin.status", PluginStatusPayloadSchema),

  // Workers
  agentMessage("worker.configure", WorkerConfigurePayloadSchema),
  agentMessage("worker.status", WorkerStatusLegacyPayloadSchema),

  // Assignments
  assignmentMessage("assignment.start", LegacyAssignmentStartPayloadSchema),
  assignmentMessage("assignment.ack", LegacyAssignmentAckPayloadSchema),
  assignmentMessage(
    "assignment.progress",
    LegacyAssignmentProgressPayloadSchema,
  ),
  assignmentMessage("assignment.result", LegacyAssignmentResultPayloadSchema),
  assignmentMessage("assignment.error", AssignmentFailurePayloadSchema),
  assignmentMessage("assignment.cancelled", AssignmentCancelledPayloadSchema),
  assignmentMessage("assignment.cancel", LegacyAssignmentCancelPayloadSchema),
  assignmentMessage(
    "assignment.cancel.ack",
    LegacyAssignmentCancelAckPayloadSchema,
  ),
]);

export type AgentProtocolMessage = z.infer<typeof AgentProtocolMessageSchema>;
export type AgentMessageType = AgentProtocolMessage["type"];

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

export function serializeAgentMessage(message: AgentProtocolMessage): string {
  const serialized = JSON.stringify(message);
  if (Buffer.byteLength(serialized, "utf8") > MAX_MESSAGE_SIZE_BYTES) {
    throw new AgentProtocolError(
      `Message size exceeds maximum allowed size of ${MAX_MESSAGE_SIZE_BYTES} bytes`,
    );
  }
  return serialized;
}

export function isAssignmentMessageType(type: string): boolean {
  return type.startsWith("assignment.");
}

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

export function reconcileAssignmentJournal(
  cloudRecords: readonly CloudAssignmentRecord[],
  agentJournal: readonly AgentJournalEntry[],
): JournalReconcileAction[] {
  const cloudMap = new Map(cloudRecords.map((c) => [c.assignmentId, c]));
  const actions: JournalReconcileAction[] = [];

  for (const entry of agentJournal) {
    const cloudRecord = cloudMap.get(entry.assignmentId);

    if (!cloudRecord) {
      actions.push({
        action: "cancel_orphaned",
        assignmentId: entry.assignmentId,
      });
      continue;
    }

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
