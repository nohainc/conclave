import { expect, it } from "vitest";
import { cancelTaskAssignment, recoverStaleAssignments } from "../src/assignment-dispatcher.js";

it("persists confirmed cancellation without waiting for terminal delivery", async () => {
  const writes: string[] = [];
  const db = {
    prepare(sql: string) {
      return {
        bind: () => ({
          first: async () => ({ status: "acknowledged", task_id: "task-1" }),
          run: async () => { writes.push(sql); },
        }),
      };
    },
  };
  const result = await cancelTaskAssignment({
    CONCLAVE_DB: db,
    CONCLAVE_WORKSPACE_GATEWAY: {
      idFromName: () => "workspace-1",
      get: () => ({ fetch: async () => Response.json({ cancelled: true }) }),
    },
  } as never, "workspace-1", "assignment-1", "User cancelled");
  expect(result.cancelled).toBe(true);
  expect(writes).toHaveLength(2);
  expect(writes[0]).toContain("UPDATE worker_assignments SET status = 'cancelled'");
  expect(writes[1]).toContain("UPDATE workflow_tasks SET status = 'cancelled'");
});

it("fails disconnected, expired, and leased assignments idempotently", async () => {
  const now = new Date("2026-10-13T12:00:00.000Z");
  const rows = [
    {
      id: "assignment-cancelled-parent",
      status: "acknowledged",
      createdAt: now.toISOString(),
      updatedAt: now.toISOString(),
      timeoutMs: null,
      workspaceStatus: "online",
      workspaceUpdatedAt: now.toISOString(),
      grantExpiresAt: null,
      workRequestStatus: "cancelled",
    },
    {
      id: "assignment-disconnected",
      status: "running",
      createdAt: "2026-10-13T11:55:00.000Z",
      updatedAt: "2026-10-13T11:55:00.000Z",
      timeoutMs: 900_000,
      workspaceStatus: "offline",
      workspaceUpdatedAt: "2026-10-13T11:55:00.000Z",
      grantExpiresAt: null,
    },
    {
      id: "assignment-timeout",
      status: "acknowledged",
      createdAt: "2026-10-13T11:30:00.000Z",
      updatedAt: "2026-10-13T11:59:00.000Z",
      timeoutMs: 60_000,
      workspaceStatus: "online",
      workspaceUpdatedAt: "2026-10-13T11:59:00.000Z",
      grantExpiresAt: null,
    },
    {
      id: "assignment-lease",
      status: "running",
      createdAt: "2026-10-13T11:59:00.000Z",
      updatedAt: "2026-10-13T11:59:30.000Z",
      timeoutMs: 900_000,
      workspaceStatus: "online",
      workspaceUpdatedAt: "2026-10-13T11:59:30.000Z",
      grantExpiresAt: "2026-10-13T11:59:59.000Z",
    },
  ];
  const updates: unknown[][] = [];
  const db = {
    prepare(sql: string) {
      return {
        all: async () => ({ results: rows }),
        bind: (...values: unknown[]) => ({
          first: async () => ({ status: "running", task_id: "task-1" }),
          run: async () => {
            if (sql.includes("UPDATE")) updates.push(values);
            return { meta: { changes: 1 } };
          },
        }),
      };
    },
  };

  expect(await recoverStaleAssignments(db as never, now)).toBe(4);
  expect(updates).toHaveLength(8);
  expect(JSON.parse(String(updates[0]?.[0])).status).toBe("cancelled");
  expect(updates[0]?.[2]).toBe("assignment-cancelled-parent");
  expect(updates.slice(2).map((values) => values[2])).toEqual([
    "assignment-disconnected",
    "task-1",
    "assignment-timeout",
    "task-1",
    "assignment-lease",
    "task-1",
  ]);
});
