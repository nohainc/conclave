import { describe, expect, it } from "vitest";
import { migrateChatToWorkstream } from "../src/index.js";

describe("v6 Chat to Workstream migration", () => {
  it("preserves IDs, migrates human content, and links historical Runs", () => {
    const result = migrateChatToWorkstream(
      {
        id: "chat-1", projectId: "project-1", workspaceId: "legacy-workspace",
        createdByUserId: "user-1", title: "Authentication", status: "active",
        createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-02T00:00:00.000Z",
      },
      [
        { id: "message-1", chatId: "chat-1", senderType: "user", senderId: "user-1", content: "Investigate login", kind: "user", metadata: {}, createdAt: "2026-01-01T01:00:00.000Z" },
        { id: "message-2", chatId: "chat-1", senderType: "conclave", senderId: "conclave", content: "Historical answer", kind: "conclave", metadata: {}, createdAt: "2026-01-01T02:00:00.000Z" },
      ],
      [{ id: "run-1", createdAt: "2026-01-01T03:00:00.000Z" }],
      "2026-01-03T00:00:00.000Z",
    );
    expect(result.workstream.id).toBe("workstream-from-chat-chat-1");
    expect(result.discussionMessages.map((message) => message.id)).toEqual(["message-1"]);
    expect(result.migration.historicalRunIds).toEqual(["run-1"]);
  });
});
