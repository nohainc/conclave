import { z } from "zod";

export const WORKSPACE_RUNTIME_PROTOCOL_NAME =
  "conclave.workspace-runtime-protocol" as const;
export const WORKSPACE_RUNTIME_PROTOCOL_VERSION = "5.0" as const;

// The checkout message names remain parseable for pre-WD-17 runtimes only.
// They are not part of the active Workstream execution flow; runtime CWD is
// resolved from Project ID + Workstream ID.
export const WORKSPACE_RUNTIME_MESSAGE_TYPES = [
  "workspace.hello",
  "workspace.hello.ack",
  "workspace.heartbeat",
  "workspace.heartbeat.ack",
  "workspace.sync.request",
  "workspace.sync.result",
  "workspace.status",
  "workspace.update",
  "worker.install",
  "worker.remove",
  "worker.status",
  "credential.status",
  "workstream.status",
  "checkout.provision",
  "checkout.status",
  "checkout.recover",
  "checkout.archive",
  "checkout.finalize",
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

export const workspaceRuntimeEnvelopeSchema = z
  .object({
    protocol: z.literal(WORKSPACE_RUNTIME_PROTOCOL_NAME),
    protocolVersion: z.literal(WORKSPACE_RUNTIME_PROTOCOL_VERSION),
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
  });

export type WorkspaceRuntimeMessage = z.infer<
  typeof workspaceRuntimeEnvelopeSchema
>;

export function parseWorkspaceRuntimeMessage(
  input: unknown,
): WorkspaceRuntimeMessage {
  return workspaceRuntimeEnvelopeSchema.parse(input);
}

export function serializeWorkspaceRuntimeMessage(
  input: WorkspaceRuntimeMessage,
): string {
  return JSON.stringify(workspaceRuntimeEnvelopeSchema.parse(input));
}
