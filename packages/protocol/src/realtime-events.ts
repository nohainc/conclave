import { z } from "zod";

import {
  DURABLE_REALTIME_EVENT_TYPES,
  REALTIME_STREAM_KINDS,
  COLLABORATION_REALTIME_EVENT_TYPES,
  EPHEMERAL_REALTIME_EVENT_TYPES,
} from "./generated.js";

const realtimeVersionPattern = /^\d+\.\d+$/;
const id = z.string().trim().min(1);
const timestamp = z.string().datetime();

export const RealtimeEventPayloadSchema = z
  .object({
    entityId: id.optional(),
    status: id.optional(),
    message: z.string().max(32768).optional(),
    summary: z.string().max(32768).optional(),
    text: z.string().max(32768).optional(),
    delta: z.string().max(8192).optional(),
    tool: id.optional(),
    artifactId: id.optional(),
    workRequestId: id.optional(),
    threadId: id.optional(),
    stepKind: id.optional(),
    leaseId: id.optional(),
    workerId: id.optional(),
    percentage: z.number().min(0).max(100).optional(),
    durationMs: z.number().int().min(0).optional(),
    tokenCount: z.number().int().min(0).optional(),
    coalesced: z.boolean().optional(),
  })
  .strict();
export type RealtimeEventPayload = z.infer<typeof RealtimeEventPayloadSchema>;

export const RealtimeStreamSchema = z
  .object({
    kind: z.enum(REALTIME_STREAM_KINDS),
    id,
  })
  .strict();
export type RealtimeStream = z.infer<typeof RealtimeStreamSchema>;

export const RealtimeEventEnvelopeSchema = z
  .object({
    eventId: id,
    type: z.string().regex(/^[a-z][a-z0-9_-]*(?:\.[a-z0-9_-]+)+$/),
    version: z.string().regex(realtimeVersionPattern),
    timestamp,
    workspaceId: id.optional(),
    stream: RealtimeStreamSchema.optional(),
    spaceId: id.optional(),
    threadId: id.optional(),
    runId: id.optional(),
    taskId: id.optional(),
    attemptId: id.optional(),
    assignmentId: id.optional(),
    workspaceRuntimeId: id.optional(),
    sequence: z.number().int().min(0),
    payload: RealtimeEventPayloadSchema,
  })
  .strict()
  .superRefine((event, context) => {
    const stream = event.stream;
    const collaboration = (
      COLLABORATION_REALTIME_EVENT_TYPES as readonly string[]
    ).includes(event.type);
    if (
      collaboration &&
      (!stream ||
        stream.kind === "execution_workspace" ||
        !event.spaceId ||
        !event.payload.entityId)
    ) {
      context.addIssue({
        code: "custom",
        message:
          "Collaboration signals require a synchronization stream, spaceId and entityId",
      });
    }
    if (
      collaboration &&
      (event.type.startsWith("thread.") ||
        event.type.startsWith("discussion.")) &&
      (!event.threadId || event.payload.threadId !== event.threadId)
    ) {
      context.addIssue({
        code: "custom",
        message: "Thread signals require matching threadId",
      });
    }
    if (
      collaboration &&
      Object.keys(event.payload).some(
        (key) => !["entityId", "threadId"].includes(key),
      )
    ) {
      context.addIssue({
        code: "custom",
        message: "Collaboration payloads contain identifiers only",
      });
    }
    if (
      !collaboration &&
      isKnownRealtimeEventType(event.type) &&
      !event.workspaceId
    ) {
      context.addIssue({
        code: "custom",
        message: "Existing execution events require workspaceId",
      });
    }
    if (
      (!stream || stream.kind === "execution_workspace") &&
      !event.workspaceId
    ) {
      context.addIssue({
        code: "custom",
        message: "Execution events require workspaceId",
      });
    }
    if (
      stream?.kind === "execution_workspace" &&
      stream.id !== event.workspaceId
    ) {
      context.addIssue({
        code: "custom",
        message: "Execution stream must match workspaceId",
      });
    }
    if (stream?.kind === "space" && stream.id !== event.spaceId) {
      context.addIssue({
        code: "custom",
        message: "Space stream must match spaceId",
      });
    }
    if (stream && stream.kind !== "execution_workspace" && event.workspaceId) {
      context.addIssue({
        code: "custom",
        message: "Synchronization streams must not invent workspaceId",
      });
    }
    if (
      stream &&
      stream.kind !== "execution_workspace" &&
      event.version === "1.0"
    ) {
      context.addIssue({
        code: "custom",
        message: "Synchronization streams require version 1.1",
      });
    }
  });
export type RealtimeEventEnvelope = z.infer<typeof RealtimeEventEnvelopeSchema>;

function versionParts(version: string): [number, number] {
  const parsed = version.match(/^(\d+)\.(\d+)$/);
  if (!parsed) throw new Error(`Invalid realtime event version: ${version}`);
  return [Number(parsed[1]), Number(parsed[2])];
}

export function isCompatibleRealtimeEventVersion(
  local: string,
  remote: string,
): boolean {
  const [localMajor, localMinor] = versionParts(local);
  const [remoteMajor, remoteMinor] = versionParts(remote);
  return localMajor === remoteMajor && remoteMinor >= localMinor;
}

export function isKnownRealtimeEventType(type: string): boolean {
  return (
    DURABLE_REALTIME_EVENT_TYPES.includes(
      type as (typeof DURABLE_REALTIME_EVENT_TYPES)[number],
    ) ||
    EPHEMERAL_REALTIME_EVENT_TYPES.includes(
      type as (typeof EPHEMERAL_REALTIME_EVENT_TYPES)[number],
    )
  );
}

export function isDurableRealtimeEventType(type: string): boolean {
  return DURABLE_REALTIME_EVENT_TYPES.includes(
    type as (typeof DURABLE_REALTIME_EVENT_TYPES)[number],
  );
}

export function isEphemeralRealtimeEventType(type: string): boolean {
  return EPHEMERAL_REALTIME_EVENT_TYPES.includes(
    type as (typeof EPHEMERAL_REALTIME_EVENT_TYPES)[number],
  );
}

/**
 * Parses facts received from Cloud realtime transport. Unknown event types are
 * retained when their event version is compatible so newer servers can add
 * facts without breaking older clients.
 */
export function parseRealtimeEvent(input: unknown): RealtimeEventEnvelope {
  const value = typeof input === "string" ? JSON.parse(input) : input;
  const event = RealtimeEventEnvelopeSchema.parse(value);
  if (!isCompatibleRealtimeEventVersion("1.0", event.version)) {
    throw new Error(`Unsupported realtime event version: ${event.version}`);
  }
  return event;
}

/** Legacy execution envelopes infer their stream from the real Workspace ID. */
export function realtimeEventStream(
  event: RealtimeEventEnvelope,
): RealtimeStream {
  return (
    event.stream ?? { kind: "execution_workspace", id: event.workspaceId! }
  );
}

/** Structured JSON keys cannot collide across stream kinds or arbitrary IDs. */
export function realtimeStreamKey(stream: RealtimeStream): string {
  return JSON.stringify([stream.kind, stream.id]);
}
