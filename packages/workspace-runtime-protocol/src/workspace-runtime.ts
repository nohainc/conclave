import { z } from "zod";
import {
  EXECUTION_PERMISSIONS,
  EXECUTION_ERROR_CODES,
  EXECUTION_ERROR_MESSAGES,
} from "@conclave/protocol";

export const WORKSPACE_RUNTIME_PROTOCOL_NAME =
  "conclave.workspace-runtime-protocol" as const;
export const WORKSPACE_RUNTIME_PROTOCOL_VERSION = "5.1" as const;
export const WORKSPACE_RUNTIME_PROTOCOL_SUPPORTED_VERSIONS = [
  "5.0",
  "5.1",
] as const;

export const WORKSPACE_RUNTIME_MESSAGE_TYPES = [
  "workspace.hello",
  "workspace.hello.ack",
  "workspace.heartbeat",
  "workspace.heartbeat.ack",
  "workspace.sync.request",
  "workspace.sync.result",
  "workspace.status",
  "workspace.update",
  "worker.inventory",
  "workstream.status",
  "assignment.start",
  "assignment.ack",
  "assignment.progress",
  "assignment.result",
  "assignment.error",
  "assignment.cancel",
  "assignment.cancel.ack",
  "assignment.cancelled",
] as const;

export type WorkspaceRuntimeMessageType =
  (typeof WORKSPACE_RUNTIME_MESSAGE_TYPES)[number];

const nonEmptyString = z.string().trim().min(1);
const timestamp = z.string().datetime();
const executionErrorCode = z.enum(EXECUTION_ERROR_CODES);

/** Canonical execution permissions carried from Cloud to Workspace. */
export const EXECUTION_PERMISSION_IDS = EXECUTION_PERMISSIONS;
const executionPermission = z.enum(EXECUTION_PERMISSIONS);

/** Product-facing Worker Type IDs; legacy provider package IDs are not valid. */
export const WorkspaceProductWorkerTypeIdSchema = nonEmptyString
  .max(128)
  .regex(/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/)
  .refine((id) => id !== "codex" && id !== "antigravity", {
    message: "legacy package IDs are not Workspace product Worker Types",
  });

export const WorkspaceWorkerInventoryEntrySchema = z
  .object({
    workerId: z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/),
    workerTypeId: WorkspaceProductWorkerTypeIdSchema,
    activationState: z.enum(["enabled", "disabled"]),
    readinessState: z.enum([
      "not_probed",
      "ready",
      "setup_required",
      "sign_in_required",
      "worker_runtime_unavailable",
      "test_failed",
    ]),
    readinessIssueCode: z
      .string()
      .regex(/^[a-z][a-z0-9_]{0,127}$/)
      .optional(),
    engineVersion: z
      .string()
      .regex(/^[A-Za-z0-9][A-Za-z0-9.+_-]{0,63}$/)
      .nullable(),
    profileDefinitionId: z
      .string()
      .regex(/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/)
      .max(96)
      .nullable(),
    profileReleaseVersion: z
      .number()
      .int()
      .positive()
      .max(Number.MAX_SAFE_INTEGER)
      .nullable(),
    providerToolName: z
      .string()
      .regex(/^[A-Za-z0-9][A-Za-z0-9 ._-]{0,127}$/)
      .nullable(),
    providerToolVersion: z
      .string()
      .regex(/^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}$/)
      .nullable(),
    capabilities: z
      .array(z.string().regex(/^[a-z][a-z0-9_:-]{0,127}$/))
      .max(128),
    localConcurrencyLimit: z.number().int().min(1).max(1024),
    revision: z.number().int().min(1).max(Number.MAX_SAFE_INTEGER),
    createdAt: timestamp,
    updatedAt: timestamp,
    lastSeenAt: timestamp,
  })
  .strict();

export const WorkerInventoryPayloadSchema = z
  .object({
    workers: z.array(WorkspaceWorkerInventoryEntrySchema).max(500),
    fullSnapshot: z.boolean(),
  })
  .strict();

export const workspaceRuntimeEnvelopeSchema = z
  .object({
    protocol: z.literal(WORKSPACE_RUNTIME_PROTOCOL_NAME),
    protocolVersion: z.enum(WORKSPACE_RUNTIME_PROTOCOL_SUPPORTED_VERSIONS),
    messageId: nonEmptyString,
    correlationId: nonEmptyString.optional(),
    timestamp,
    type: z.enum(WORKSPACE_RUNTIME_MESSAGE_TYPES),
    executionWorkspaceId: nonEmptyString.optional(),
    workspaceRuntimeId: nonEmptyString.optional(),
    workerId: nonEmptyString.optional(),
    runId: nonEmptyString.optional(),
    taskId: nonEmptyString.optional(),
    attemptId: nonEmptyString.optional(),
    assignmentId: nonEmptyString.optional(),
    idempotencyKey: nonEmptyString.optional(),
    payload: z.unknown(),
  })
  .strict()
  .superRefine((message, ctx) => {
    if (message.type.startsWith("assignment.")) {
      for (const field of [
        "executionWorkspaceId",
        "workspaceRuntimeId",
        "workerId",
        "runId",
        "taskId",
        "attemptId",
        "assignmentId",
        "idempotencyKey",
      ] as const) {
        if (!message[field]) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            path: [field],
            message: `${field} is required for assignment messages`,
          });
        }
      }
    }
    if (message.type === "assignment.start") {
      const payload = z
        .object({
          snapshot: z
            .object({
              workerTypeId: WorkspaceProductWorkerTypeIdSchema,
              permissions: z.array(executionPermission).optional(),
              permissionSnapshot: z
                .object({
                  permissions: z.array(executionPermission),
                })
                .passthrough()
                .optional(),
              readOnly: z.boolean().optional(),
              sessionPolicy: z
                .enum(["stateless", "durable_session"])
                .optional(),
              sessionKey: nonEmptyString.max(256).optional(),
            })
            .superRefine((snapshot, ctx) => {
              if (
                (snapshot.sessionPolicy === "stateless" &&
                  snapshot.sessionKey !== undefined) ||
                (snapshot.sessionPolicy === "durable_session" &&
                  snapshot.sessionKey === undefined)
              ) {
                ctx.addIssue({
                  code: z.ZodIssueCode.custom,
                  path: ["sessionKey"],
                  message:
                    "Session policy and logical session key are inconsistent",
                });
              }
            })
            .superRefine((snapshot, ctx) => {
              if (
                snapshot.permissions &&
                snapshot.permissionSnapshot &&
                JSON.stringify(snapshot.permissions) !==
                  JSON.stringify(snapshot.permissionSnapshot.permissions)
              ) {
                ctx.addIssue({
                  code: z.ZodIssueCode.custom,
                  path: ["permissionSnapshot", "permissions"],
                  message: "assignment permission fields must match",
                });
              }
            })
            .passthrough(),
          permissions: z.array(executionPermission).optional(),
          input: z.record(z.string(), z.unknown()).optional(),
        })
        .passthrough()
        .safeParse(message.payload);
      if (!payload.success) {
        for (const issue of payload.error.issues) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            path: ["payload", ...issue.path],
            message: issue.message,
          });
        }
      }
    }
    if (message.type === "assignment.error") {
      const payload = z
        .object({
          error: z
            .object({
              code: executionErrorCode,
              message: nonEmptyString.max(512),
              retryable: z.boolean(),
            })
            .strict()
            .superRefine((error, errorCtx) => {
              if (error.message !== EXECUTION_ERROR_MESSAGES[error.code]) {
                errorCtx.addIssue({
                  code: z.ZodIssueCode.custom,
                  path: ["message"],
                  message:
                    "assignment errors must use the canonical safe message",
                });
              }
            }),
        })
        .passthrough()
        .safeParse(message.payload);
      if (!payload.success) {
        for (const issue of payload.error.issues) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            path: ["payload", ...issue.path],
            message: issue.message,
          });
        }
      }
    }
  });

export type WorkspaceRuntimeMessage = z.infer<
  typeof workspaceRuntimeEnvelopeSchema
>;

export function parseWorkspaceRuntimeMessage(
  input: unknown,
): WorkspaceRuntimeMessage {
  const message = workspaceRuntimeEnvelopeSchema.parse(input);
  if (message.type === "worker.inventory") {
    if (message.protocolVersion !== "5.1") {
      throw new Error("worker.inventory requires Workspace protocol 5.1");
    }
    WorkerInventoryPayloadSchema.parse(message.payload);
  }
  return message;
}

export function serializeWorkspaceRuntimeMessage(
  input: WorkspaceRuntimeMessage,
): string {
  return JSON.stringify(parseWorkspaceRuntimeMessage(input));
}
