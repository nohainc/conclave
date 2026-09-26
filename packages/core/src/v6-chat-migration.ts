import type { Chat, ChatMessage } from "./entities.js";
import {
  DEFAULT_WORKSTREAM_ACCESS_POLICY,
  type DiscussionMessage,
  type Workstream,
} from "./v6-entities.js";

export interface LegacyChatRunReference {
  readonly id: string;
  readonly createdAt: string;
}

export interface ChatWorkstreamMigration {
  readonly chatId: string;
  readonly workstreamId: string;
  readonly discussionMessageIds: readonly string[];
  readonly historicalRunIds: readonly string[];
  readonly migratedAt: string;
}

export interface MigratedChatWorkstream {
  readonly workstream: Workstream;
  readonly discussionMessages: readonly DiscussionMessage[];
  readonly migration: ChatWorkstreamMigration;
}

/**
 * Clean-room migration helper for preserving fixtures or an opt-in dev
 * dataset. Chat never becomes a Work Request; historical Runs remain linked
 * activity references for the resulting Workstream.
 */
export function migrateChatToWorkstream(
  chat: Chat,
  messages: readonly ChatMessage[],
  runs: readonly LegacyChatRunReference[],
  migratedAt: string,
): MigratedChatWorkstream {
  const workstreamId = `workstream-from-chat-${chat.id}`;
  const workstream: Workstream = {
    id: workstreamId,
    projectId: chat.projectId,
    name: chat.title,
    status: chat.status === "archived" ? "archived" : "active",
    accessPolicy: DEFAULT_WORKSTREAM_ACCESS_POLICY,
    lead: {
      userId: chat.createdByUserId,
      assignedAt: chat.createdAt,
      assignedByUserId: chat.createdByUserId,
    },
    createdAt: chat.createdAt,
    updatedAt: chat.updatedAt,
  };
  const discussionMessages = messages
    .filter(
      (message) => message.chatId === chat.id && message.senderType === "user",
    )
    .sort((left, right) => left.createdAt.localeCompare(right.createdAt))
    .map((message) => ({
      id: message.id,
      workstreamId,
      authorUserId: message.senderId,
      body: message.content,
      createdAt: message.createdAt,
      editedAt: null,
    }));
  return {
    workstream,
    discussionMessages,
    migration: {
      chatId: chat.id,
      workstreamId,
      discussionMessageIds: discussionMessages.map((message) => message.id),
      historicalRunIds: runs.map((run) => run.id),
      migratedAt,
    },
  };
}
