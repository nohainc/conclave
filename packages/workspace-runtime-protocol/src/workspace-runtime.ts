import { z } from "zod";
import {
  EXECUTION_PERMISSIONS,
  EXECUTION_ERROR_CODES,
  EXECUTION_ERROR_MESSAGES,
  NORMALIZED_ACTIVITY_EVENT_TYPES,
  NORMALIZED_ACTIVITY_STATUSES,
  NormalizedActivityDetailsSchema,
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
  "thread.status",
  "assignment.start",
  "assignment.start.ack",
  "assignment.ack",
  "assignment.activity",
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
const workerActivityPayload = z
  .object({
    assignmentId: nonEmptyString.max(128),
    executionId: nonEmptyString.max(128),
    workerId: nonEmptyString.max(128),
    eventId: nonEmptyString.max(128),
    sequence: z.number().int().positive().max(2_147_483_647),
    timestamp,
    eventType: z.enum(NORMALIZED_ACTIVITY_EVENT_TYPES),
    status: z.enum(NORMALIZED_ACTIVITY_STATUSES),
    title: z.string().min(1).max(256),
    activityId: nonEmptyString.max(128).optional(),
    percentage: z.number().min(0).max(100).optional(),
    details: NormalizedActivityDetailsSchema.optional(),
    durationMs: z.number().int().min(0).optional(),
    toolId: nonEmptyString.max(128).optional(),
    toolName: nonEmptyString.max(128).optional(),
  })
  .strict();

/** Product-facing Worker Type IDs; legacy provider package IDs are not valid. */
export const WorkspaceProductWorkerTypeIdSchema = nonEmptyString
  .max(128)
  .regex(/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/)
  .refine((id) => id !== "codex" && id !== "antigravity", {
    message: "legacy package IDs are not Workspace product Worker Types",
  });

const DiscoveredModelCatalogV1Schema = z
  .object({
    schemaVersion: z.literal(1),
    profileDigest: z.string().regex(/^[0-9a-f]{64}$/),
    providerToolVersion: z
      .string()
      .regex(/^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}$/),
    discoveredAt: timestamp,
    models: z
      .array(
        z
          .object({
            id: z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/),
            name: z
              .string()
              .min(1)
              .max(256)
              .regex(/^[^\x00-\x1f\x7f]+$/),
            status: z.enum(["listed", "verified", "unavailable"]),
            supportedReasoningEfforts: z
              .array(z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/))
              .max(16)
              .refine(
                (efforts) => new Set(efforts).size === efforts.length,
                "Duplicate reasoning efforts",
              )
              .optional(),
            defaultReasoningEffort: z
              .string()
              .regex(/^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/)
              .optional(),
          })
          .strict()
          .superRefine((model, ctx) => {
            if (
              model.defaultReasoningEffort !== undefined &&
              !model.supportedReasoningEfforts?.includes(
                model.defaultReasoningEffort,
              )
            ) {
              ctx.addIssue({
                code: z.ZodIssueCode.custom,
                path: ["defaultReasoningEffort"],
                message: "Default reasoning effort must be listed as supported",
              });
            }
          }),
      )
      .max(128)
      .refine(
        (models) => new Set(models.map((m) => m.id)).size === models.length,
        "Duplicate model IDs",
      ),
  })
  .strict();

/** Sanitized inventory: native IDs/mappings are forbidden at this boundary. */
export const DiscoveredModelCatalogV2Schema = z
  .object({
    schemaVersion: z.literal(2),
    stale: z.boolean().optional(),
    catalogRevision: z.string().regex(/^[0-9a-f]{64}$/),
    profileDigest: z.string().regex(/^[0-9a-f]{64}$/),
    providerToolVersion: z
      .string()
      .regex(/^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}$/),
    discoveredAt: timestamp,
    models: z
      .array(
        z
          .object({
            id: z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/),
            name: z
              .string()
              .min(1)
              .max(256)
              .regex(/^[^\x00-\x1f\x7f]+$/),
            status: z.enum(["listed", "verified", "unavailable"]),
            selectionMode: z.enum(["separate", "combined"]),
            efforts: z
              .array(z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/))
              .max(16)
              .refine(
                (values) => new Set(values).size === values.length,
                "Duplicate efforts",
              )
              .default([]),
            defaultEffort: z
              .string()
              .regex(/^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/)
              .nullable()
              .default(null),
          })
          .strict()
          .superRefine((model, ctx) => {
            if (
              model.defaultEffort !== null &&
              !model.efforts.includes(model.defaultEffort)
            ) {
              ctx.addIssue({
                code: "custom",
                path: ["defaultEffort"],
                message: "Default effort must be supported",
              });
            }
          }),
      )
      .max(128)
      .refine(
        (models) => new Set(models.map((m) => m.id)).size === models.length,
        "Duplicate model IDs",
      ),
  })
  .strict();
export const DiscoveredModelCatalogSchema = z.union([
  DiscoveredModelCatalogV1Schema,
  DiscoveredModelCatalogV2Schema,
]);

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
    modelCatalog: DiscoveredModelCatalogSchema.optional(),
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
              executionSelection: z
                .object({
                  schemaVersion: z.literal(1),
                  catalogSource: z.enum([
                    "provider_catalog",
                    "profile_catalog",
                  ]),
                  workerTypeId: WorkspaceProductWorkerTypeIdSchema,
                  workerDisplayName: nonEmptyString.max(256),
                  profileReleaseVersion: z.number().int().positive(),
                  modelId: nonEmptyString.max(128).nullable(),
                  modelName: nonEmptyString.max(256).nullable(),
                  effort: nonEmptyString.max(128).nullable(),
                  catalogRevision: z
                    .string()
                    .regex(/^[a-f0-9]{64}$/)
                    .nullable(),
                  modelSource: z.enum([
                    "explicit",
                    "catalog_default",
                    "provider_default",
                  ]),
                  effortSource: z.enum([
                    "explicit",
                    "catalog_default",
                    "provider_default",
                  ]),
                })
                .strict()
                .optional(),
              permissions: z.array(executionPermission).optional(),
              permissionSnapshot: z
                .object({
                  permissions: z.array(executionPermission),
                })
                .passthrough()
                .optional(),
              model: nonEmptyString.max(128).nullable().optional(),
              reasoningEffort: nonEmptyString.max(128).nullable().optional(),
              readOnly: z.boolean().optional(),
              sessionPolicy: z
                .enum(["stateless", "durable_session"])
                .optional(),
              sessionKey: nonEmptyString.max(256).optional(),
            })
            .superRefine((snapshot, ctx) => {
              if (
                snapshot.executionSelection &&
                (snapshot.executionSelection.workerTypeId !==
                  snapshot.workerTypeId ||
                  snapshot.executionSelection.modelId !==
                    (snapshot.model ?? null) ||
                  snapshot.executionSelection.effort !==
                    (snapshot.reasoningEffort ?? null))
              ) {
                ctx.addIssue({
                  code: z.ZodIssueCode.custom,
                  path: ["executionSelection"],
                  message: "Frozen selection must match assignment invocation",
                });
              }

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
              details: z
                .record(
                  z.string().regex(/^[A-Za-z][A-Za-z0-9_-]{0,63}$/),
                  z.union([
                    z.string().max(2048),
                    z.number(),
                    z.boolean(),
                    z.null(),
                  ]),
                )
                .optional(),
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
    if (message.type === "assignment.start.ack") {
      const payload = z
        .object({
          started: z.literal(true),
          engineStarted: z.literal(true),
          providerStarted: z.literal(true),
          startedAt: timestamp.optional(),
        })
        .strict()
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
    if (message.type === "assignment.activity") {
      const payload = workerActivityPayload.safeParse(message.payload);
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
