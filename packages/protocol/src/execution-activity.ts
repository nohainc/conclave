import { z } from "zod";

/** The provider-independent activity vocabulary shared by Engine, Service, Cloud and AX. */
export const NORMALIZED_ACTIVITY_EVENT_TYPES = [
  "execution.started",
  "model.started",
  "model.status",
  "message.updated",
  "tool.started",
  "tool.completed",
  "tool.failed",
  "execution.completed",
  "execution.failed",
  "execution.cancelled",
  "execution.timed_out",
  "execution.lost",
] as const;

export const NORMALIZED_ACTIVITY_STATUSES = [
  "running",
  "updated",
  "completed",
  "failed",
  "cancelled",
  "timed_out",
  "lost",
] as const;

const scalar = z.union([
  z.string().max(2048),
  z.number().finite(),
  z.boolean(),
  z.null(),
]);

const unsafeDetailKey =
  /(prompt|content|text|output|stdout|stderr|argument|command|environment|^env$|token|secret|password|api[_-]?key|credential|reasoning|file[_-]?(content|contents|data|text|body|value))/i;

export const NormalizedActivityDetailsSchema = z
  .record(z.string().regex(/^[A-Za-z][A-Za-z0-9_-]{0,63}$/), scalar)
  .superRefine((details, context) => {
    if (Object.keys(details).length > 32) {
      context.addIssue({
        code: "custom",
        message: "Activity details exceed 32 fields",
      });
    }
    for (const key of Object.keys(details)) {
      if (unsafeDetailKey.test(key)) {
        context.addIssue({
          code: "custom",
          path: [key],
          message: "Activity details cannot contain provider content",
        });
      }
    }
  });

export const NormalizedActivityPayloadSchema = z
  .object({
    title: z.string().trim().min(1).max(256),
    status: z.enum(NORMALIZED_ACTIVITY_STATUSES),
    activityId: z.string().trim().min(1).max(128).optional(),
    percentage: z.number().finite().min(0).max(100).optional(),
    durationMs: z.number().int().min(0).max(86_400_000).optional(),
    toolId: z.string().trim().min(1).max(128).optional(),
    toolName: z.string().trim().min(1).max(128).optional(),
    details: NormalizedActivityDetailsSchema.optional(),
  })
  .strict();

export type NormalizedActivityPayload = z.infer<
  typeof NormalizedActivityPayloadSchema
>;
export type NormalizedActivityEventType =
  (typeof NORMALIZED_ACTIVITY_EVENT_TYPES)[number];

/** Drop unsafe or structurally invalid provider data before it reaches a wire payload. */
export function sanitizeActivityDetails(
  input: unknown,
): Record<string, unknown> {
  if (!input || typeof input !== "object" || Array.isArray(input)) return {};
  const output: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(input)) {
    if (
      !/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(key) ||
      unsafeDetailKey.test(key) ||
      Object.keys(output).length >= 32
    ) {
      continue;
    }
    if (
      value === null ||
      typeof value === "boolean" ||
      (typeof value === "number" && Number.isFinite(value))
    ) {
      output[key] = value;
    } else if (typeof value === "string") {
      // eslint-disable-next-line no-control-regex -- Remove control bytes from activity payload text.
      const safe = value.replace(/[\u0000-\u001f\u007f]/g, " ").trim();
      if (safe) output[key] = safe.slice(0, 2048);
    }
  }
  return output;
}

export function normalizeActivityPayload(
  input: unknown,
): NormalizedActivityPayload | null {
  if (!input || typeof input !== "object" || Array.isArray(input)) return null;
  const raw = input as Record<string, unknown>;
  const details = sanitizeActivityDetails(raw.details);
  const candidate = {
    title:
      typeof raw.title === "string"
        ? raw.title
            // eslint-disable-next-line no-control-regex -- Remove control bytes from activity payload text.
            .replace(/[\u0000-\u001f\u007f]/g, " ")
            .trim()
            .slice(0, 256)
        : "",
    status: raw.status,
    ...(typeof raw.activityId === "string"
      ? { activityId: raw.activityId }
      : {}),
    ...(typeof raw.percentage === "number" && Number.isFinite(raw.percentage)
      ? { percentage: raw.percentage }
      : {}),
    ...(typeof raw.durationMs === "number" && Number.isInteger(raw.durationMs)
      ? { durationMs: raw.durationMs }
      : {}),
    ...(typeof raw.toolId === "string" ? { toolId: raw.toolId } : {}),
    ...(typeof raw.toolName === "string" ? { toolName: raw.toolName } : {}),
    ...(Object.keys(details).length ? { details } : {}),
  };
  const parsed = NormalizedActivityPayloadSchema.safeParse(candidate);
  return parsed.success ? parsed.data : null;
}
