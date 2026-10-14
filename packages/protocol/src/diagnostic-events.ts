import { z } from "zod";

export const DIAGNOSTIC_EVENT_SCHEMA_VERSION = 1 as const;

/** Shared trace stages used to follow one assignment across Cloud and Service. */
export const EXECUTION_TRACE_STAGES = [
  "dispatch",
  "accepted",
  "slot_reservation",
  "engine_startup",
  "provider_execution",
  "activity_forwarding",
  "terminal_recorded",
  "terminal_acknowledgement",
] as const;
export type ExecutionTraceStage = (typeof EXECUTION_TRACE_STAGES)[number];

const boundedToken = z
  .string()
  .min(1)
  .max(128)
  .regex(/^[A-Za-z0-9._:-]+$/);

/** Closed diagnostic context: values are bounded scalars only. */
export const DiagnosticContextSchema = z
  .object({
    workspaceVersion: boundedToken.optional(),
    engineVersion: boundedToken.optional(),
    profileDefinitionId: boundedToken.optional(),
    profileReleaseVersion: z.number().int().positive().optional(),
    profileResolutionSource: boundedToken.optional(),
    profileDigest: z
      .string()
      .regex(/^[a-f0-9]{64}$/)
      .optional(),
    providerToolName: z.string().min(1).max(128).optional(),
    providerToolVersion: boundedToken.optional(),
    protocolStage: boundedToken.optional(),
    failureLayer: boundedToken.optional(),
    processExitCode: z.number().int().optional(),
    durationMs: z.number().int().nonnegative().max(2_147_483_647).optional(),
    connectionState: boundedToken.optional(),
    transport: boundedToken.optional(),
    status: boundedToken.optional(),
    modelId: boundedToken.optional(),
    effort: boundedToken.optional(),
    catalogRevision: z
      .string()
      .regex(/^[a-f0-9]{64}$/)
      .optional(),
    selectionSource: boundedToken.optional(),
    lineBytes: z.number().int().nonnegative().max(4_194_304).optional(),
    httpStatusCode: z.number().int().min(100).max(599).optional(),
    recovered: z.boolean().optional(),
  })
  .strict();

export const DiagnosticEventSchema = z
  .object({
    schemaVersion: z.literal(DIAGNOSTIC_EVENT_SCHEMA_VERSION),
    eventId: boundedToken,
    timestamp: z.string().datetime({ offset: true }),
    requestId: boundedToken.optional(),
    assignmentId: boundedToken.optional(),
    workspaceId: boundedToken.optional(),
    workspaceRuntimeId: boundedToken.optional(),
    workerId: boundedToken.optional(),
    workerTypeId: boundedToken.optional(),
    runId: boundedToken.optional(),
    taskId: boundedToken.optional(),
    attemptId: boundedToken.optional(),
    component: boundedToken,
    operation: boundedToken,
    stage: boundedToken,
    severity: z.enum(["debug", "info", "warning", "error"]),
    errorCode: boundedToken.optional(),
    retryable: z.boolean(),
    context: DiagnosticContextSchema.optional(),
  })
  .strict();

export type DiagnosticEvent = z.infer<typeof DiagnosticEventSchema>;
export type DiagnosticContext = z.infer<typeof DiagnosticContextSchema>;

export function createDiagnosticEvent(
  input: Omit<DiagnosticEvent, "schemaVersion" | "eventId" | "timestamp"> &
    Partial<Pick<DiagnosticEvent, "eventId" | "timestamp">>,
): DiagnosticEvent {
  return DiagnosticEventSchema.parse({
    ...input,
    schemaVersion: DIAGNOSTIC_EVENT_SCHEMA_VERSION,
    eventId: input.eventId ?? `diag-${crypto.randomUUID()}`,
    timestamp: input.timestamp ?? new Date().toISOString(),
  });
}

/** Fails closed when a provider or Workspace sends an unexpected shape. */
export function parseDiagnosticEvent(input: unknown): DiagnosticEvent {
  return DiagnosticEventSchema.parse(input);
}
