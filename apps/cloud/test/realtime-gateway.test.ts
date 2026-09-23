import { describe, expect, it } from "vitest";
import {
  authorizeRealtimeScope,
  eventMatchesScope,
  parseRealtimeClientMessage,
  realtimeAuthenticationError,
  reconnectDelayMs,
  scopeKey,
} from "../src/realtime-gateway.js";

const identity = {
  userId: "user-1",
  email: "user@example.com",
  name: "User",
  sessionId: "session-1",
};

describe("realtime gateway contract", () => {
  it("rejects signed-out or suspended identities and accepts active sessions", () => {
    expect(realtimeAuthenticationError(null)).toBe("Authentication required");
    expect(realtimeAuthenticationError(identity, "suspended")).toBe(
      "User account is suspended",
    );
    expect(realtimeAuthenticationError(identity, "active")).toBeNull();
  });

  it("parses scoped control messages and rejects missing workspace scope", () => {
    expect(
      parseRealtimeClientMessage({
        type: "subscribe",
        scope: { workspaceId: "workspace-1", projectId: "project-1" },
      }),
    ).toEqual({
      type: "subscribe",
      scope: { workspaceId: "workspace-1", projectId: "project-1" },
    });
    expect(() =>
      parseRealtimeClientMessage({ type: "subscribe", scope: {} }),
    ).toThrow("workspaceId");
    expect(() => parseRealtimeClientMessage({ type: "unknown" })).toThrow();
  });

  it("matches events only within the requested scope", () => {
    expect(
      eventMatchesScope(
        {
          eventId: "event-1",
          type: "run.completed",
          version: "1.0",
          timestamp: "2026-09-23T00:00:00.000Z",
          workspaceId: "workspace-1",
          projectId: "project-1",
          sequence: 1,
          payload: {},
        },
        { workspaceId: "workspace-1", projectId: "project-1" },
      ),
    ).toBe(true);
    expect(
      eventMatchesScope(
        {
          eventId: "event-1",
          type: "run.completed",
          version: "1.0",
          timestamp: "2026-09-23T00:00:00.000Z",
          workspaceId: "workspace-2",
          sequence: 1,
          payload: {},
        },
        { workspaceId: "workspace-1" },
      ),
    ).toBe(false);
    expect(scopeKey({ workspaceId: "workspace-1" })).toBe(
      "workspaceId=workspace-1&projectId=&chatId=&runId=",
    );
  });

  it("uses bounded exponential reconnect backoff with jitter", () => {
    expect(reconnectDelayMs(0, 0)).toBe(375);
    expect(reconnectDelayMs(3, 1)).toBe(5000);
    expect(reconnectDelayMs(99, 0)).toBe(22500);
  });

  it("requires active Workspace membership and validates nested scopes", async () => {
    const queries: string[] = [];
    const db = {
      prepare(query: string) {
        queries.push(query);
        return {
          bind(...args: unknown[]) {
            return {
              first: async () => {
                if (query.includes("workspace_memberships"))
                  return { member: 1 };
                if (query.includes("FROM projects")) {
                  return {
                    workspace_id:
                      args[0] === "project-1" ? "workspace-1" : "workspace-2",
                  };
                }
                return null;
              },
            };
          },
        };
      },
    } as never;
    await expect(
      authorizeRealtimeScope(db, "user-1", {
        workspaceId: "workspace-1",
        projectId: "project-1",
      }),
    ).resolves.toEqual({ allowed: true });
    await expect(
      authorizeRealtimeScope(db, "user-1", {
        workspaceId: "workspace-1",
        projectId: "project-2",
      }),
    ).resolves.toEqual({ allowed: false, reason: "project_access_denied" });
    expect(
      queries.some((query) => query.includes("workspace_memberships")),
    ).toBe(true);
  });
});
