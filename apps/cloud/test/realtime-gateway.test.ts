import { describe, expect, it } from "vitest";
import {
  authorizeRealtimeScope,
  eventMatchesScope,
  isRealtimeIdentityAuthorized,
  parseRealtimeClientMessage,
  realtimeAuthenticationError,
  reconnectDelayMs,
  requiresRealtimeReconnect,
  scopeKey,
} from "../src/realtime-gateway.js";
import { BoundedRealtimeQueue } from "../src/realtime-queue.js";

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

  it("parses v5 user, Project, and execution Workspace scopes", () => {
    expect(
      parseRealtimeClientMessage({
        type: "subscribe",
        scope: { kind: "user" },
      }),
    ).toEqual({ type: "subscribe", scope: { kind: "user" } });
    expect(
      parseRealtimeClientMessage({
        type: "subscribe",
        scope: { kind: "project", projectId: "project-1" },
      }),
    ).toEqual({
      type: "subscribe",
      scope: { kind: "project", projectId: "project-1" },
    });
    expect(
      parseRealtimeClientMessage({
        type: "subscribe",
        scope: {
          kind: "execution_workspace",
          executionWorkspaceId: "workspace-1",
        },
      }),
    ).toEqual({
      type: "subscribe",
      scope: {
        kind: "execution_workspace",
        executionWorkspaceId: "workspace-1",
      },
    });
    expect(scopeKey({ kind: "project", projectId: "project-1" })).toBe(
      "project=project-1",
    );
    expect(scopeKey({ kind: "workstream", workstreamId: "workstream-1" })).toBe(
      "workstream=workstream-1",
    );
    expect(
      parseRealtimeClientMessage({
        type: "subscribe",
        scope: { kind: "workstream", workstreamId: "workstream-1" },
      }),
    ).toEqual({
      type: "subscribe",
      scope: { kind: "workstream", workstreamId: "workstream-1" },
    });
  });

  it("matches v5 scopes by Project and execution Workspace identity", () => {
    const event = {
      eventId: "event-1",
      type: "run.completed",
      version: "1.0",
      timestamp: "2026-09-23T00:00:00.000Z",
      workspaceId: "workspace-1",
      projectId: "project-1",
      sequence: 1,
      payload: {},
    } as const;
    expect(eventMatchesScope(event, { kind: "user" })).toBe(true);
    expect(
      eventMatchesScope(event, { kind: "project", projectId: "project-1" }),
    ).toBe(true);
    expect(
      eventMatchesScope(event, { kind: "project", projectId: "project-2" }),
    ).toBe(false);
    expect(
      eventMatchesScope(event, {
        kind: "execution_workspace",
        executionWorkspaceId: "workspace-1",
      }),
    ).toBe(true);
    expect(
      eventMatchesScope(
        { ...event, workstreamId: "workstream-1" },
        { kind: "workstream", workstreamId: "workstream-1" },
      ),
    ).toBe(true);
    expect(
      eventMatchesScope(
        { ...event, workstreamId: "workstream-2" },
        { kind: "workstream", workstreamId: "workstream-1" },
      ),
    ).toBe(false);
  });

  it("uses bounded exponential reconnect backoff with jitter", () => {
    expect(reconnectDelayMs(0, 0)).toBe(375);
    expect(reconnectDelayMs(3, 1)).toBe(5000);
    expect(reconnectDelayMs(99, 0)).toBe(22500);
  });

  it("detects durable sequence gaps for HTTP resync", () => {
    expect(requiresRealtimeReconnect(null, 4)).toBe(false);
    expect(requiresRealtimeReconnect(3, 4)).toBe(false);
    expect(requiresRealtimeReconnect(3, 5)).toBe(true);
  });

  it("coalesces ephemeral progress and preserves durable frames in a bounded queue", () => {
    const queue = new BoundedRealtimeQueue(2);
    expect(
      queue.enqueue({
        frame: "progress-1",
        durable: false,
        coalesceKey: "run-1",
      }),
    ).toBe("queued");
    expect(
      queue.enqueue({
        frame: "progress-2",
        durable: false,
        coalesceKey: "run-1",
      }),
    ).toBe("coalesced");
    expect(queue.enqueue({ frame: "domain-1", durable: true })).toBe("queued");
    expect(queue.enqueue({ frame: "domain-2", durable: true })).toBe("queued");
    expect(queue.enqueue({ frame: "domain-3", durable: true })).toBe(
      "resync-required",
    );
    expect(queue.drain().map((item) => item.frame)).toEqual([
      "domain-1",
      "domain-2",
    ]);
  });

  it("drops noisy ephemeral frames once the queue is full", () => {
    const queue = new BoundedRealtimeQueue(1);
    expect(queue.enqueue({ frame: "status-1", durable: false })).toBe("queued");
    expect(queue.enqueue({ frame: "status-2", durable: false })).toBe(
      "dropped",
    );
    expect(queue.depth).toBe(1);
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

  it("revalidates suspended users and removed subscriptions", async () => {
    const db = {
      prepare(query: string) {
        return {
          bind() {
            return {
              first: async () => {
                if (query.includes("FROM users")) return { status: "active" };
                if (query.includes("workspace_memberships")) return null;
                return null;
              },
            };
          },
        };
      },
    } as never;
    await expect(
      isRealtimeIdentityAuthorized(db, "user-1", [
        { workspaceId: "workspace-removed" },
      ]),
    ).resolves.toBe(false);
  });
});
