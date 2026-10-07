import {
  createEventPublisher,
  type EventPublisherEnv,
} from "./event-publisher.js";

import { COLLABORATION_REALTIME_EVENT_TYPES } from "@conclave/protocol";
export type CollaborationEventType =
  (typeof COLLABORATION_REALTIME_EVENT_TYPES)[number];

/** Authenticated routes supply IDs only; collaboration has no execution owner. */
export async function publishCollaborationEvent(
  env: EventPublisherEnv,
  type: CollaborationEventType,
  projectId: string,
  entityId: string,
  options: {
    workstreamId?: string;
    recipientUserIds?: readonly string[];
    additionalRecipientUserIds?: readonly string[];
    mutations?: readonly D1PreparedStatement[];
  } = {},
): Promise<void> {
  const publisher = createEventPublisher(env);
  const payload = {
    entityId,
    ...(options.workstreamId ? { workstreamId: options.workstreamId } : {}),
  };
  await publisher.publish({
    type,
    projectId,
    stream: { kind: "project", id: projectId },
    workstreamId: options.workstreamId,
    payload,
    recipientUserIds: options.recipientUserIds,
    mutations: options.mutations,
  });
  // Invitees and removed members cannot subscribe to the Project stream.
  // Give them an ID-only invalidation on their own authorized, replayable stream.
  for (const userId of new Set(options.additionalRecipientUserIds ?? [])) {
    await publisher.publish({
      type,
      projectId,
      stream: { kind: "user", id: userId },
      payload,
      recipientUserIds: [userId],
    });
  }
}
