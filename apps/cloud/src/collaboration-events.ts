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
  await createEventPublisher(env).publish({
    type,
    projectId,
    stream: { kind: "project", id: projectId },
    workstreamId: options.workstreamId,
    payload: {
      entityId,
      ...(options.workstreamId ? { workstreamId: options.workstreamId } : {}),
    },
    recipientUserIds: options.recipientUserIds,
    additionalRecipientUserIds: options.additionalRecipientUserIds,
    mutations: options.mutations,
  });
}
