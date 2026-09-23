import { z } from "zod";

import {
  DURABLE_REALTIME_EVENT_TYPES,
  EPHEMERAL_REALTIME_EVENT_TYPES,
  REALTIME_EVENTS_VERSION,
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
    findingId: id.optional(),
    verificationId: id.optional(),
    hostId: id.optional(),
    workerId: id.optional(),
    credentialProfileId: id.optional(),
    percentage: z.number().min(0).max(100).optional(),
    durationMs: z.number().int().min(0).optional(),
    tokenCount: z.number().int().min(0).optional(),
    coalesced: z.boolean().optional(),
  })
  .strict();
export type RealtimeEventPayload = z.infer<typeof RealtimeEventPayloadSchema>;

export const RealtimeEventEnvelopeSchema = z
  .object({
    eventId: id,
    type: z.string().regex(/^[a-z][a-z0-9_-]*(?:\.[a-z0-9_-]+)+$/),
    version: z.string().regex(realtimeVersionPattern),
    timestamp,
    workspaceId: id,
    projectId: id.optional(),
    chatId: id.optional(),
    runId: id.optional(),
    taskId: id.optional(),
    attemptId: id.optional(),
    assignmentId: id.optional(),
    hostId: id.optional(),
    sequence: z.number().int().min(0),
    payload: RealtimeEventPayloadSchema,
  })
  .strict();
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
  if (
    !isCompatibleRealtimeEventVersion(REALTIME_EVENTS_VERSION, event.version)
  ) {
    throw new Error(`Unsupported realtime event version: ${event.version}`);
  }
  return event;
}
