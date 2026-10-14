import { describe, expect, it } from "vitest";
import { beginAssignmentRevocation } from "../src/assignment-revocation.js";
import { gatewayFixture } from "./helpers/assignment-gateway.js";
import { START_PERMIT_CAPABILITY } from "../src/workspace-gateway/contracts.js";

const timeoutIntent = {
  status: "timed_out",
  reason: "The assignment exceeded its time limit.",
  source: "execution_deadline",
  failure: {
    error: {
      code: "timeout",
      message: "The assignment exceeded its time limit.",
      retryable: true,
    },
    failedAt: "2026-10-14T10:00:00.000Z",
  },
} as const;

const started = { started: true, engineStarted: true, providerStarted: true };
const types = (messages: Array<{ type: string }>) =>
  messages.map((message) => message.type);

async function revoked(initial: string) {
  const f = await gatewayFixture(initial);
  const begun = await beginAssignmentRevocation(f.db as never, {
    assignmentId: "A1",
    attemptId: "ATT1",
    intent: timeoutIntent,
  });
  expect(begun.outcome).toBe("pending");
  return f;
}

describe("Gateway delivery and revocation", () => {
  it("persists delivery before it writes the command, and queues exactly one start", async () => {
    const f = await gatewayFixture("created");
    expect(f.status().status).toBe("created");
    const response = await f.dispatch();
    expect(response.status).toBe(200);
    expect(f.status().status).toBe("dispatched");
    expect(types(await f.outbound())).toEqual(["assignment.start"]);
  });

  it("never queues a start for an assignment Cloud has begun revoking", async () => {
    for (const initial of ["acknowledged", "dispatched", "running"]) {
      const f = await revoked(initial);
      await f.outbound();
      const response = await f.dispatch();
      expect(await response.json()).toMatchObject({
        delivered: false,
        shouldSend: false,
      });
      expect(types(await f.outbound())).not.toContain("assignment.start");
      expect(f.status().status).toBe("revocation_pending");
    }
  });

  it("refuses to deliver an assignment revoked before it was ever sent", async () => {
    const f = await gatewayFixture("created");
    await beginAssignmentRevocation(f.db as never, {
      assignmentId: "A1",
      attemptId: "ATT1",
      intent: timeoutIntent,
    });
    // `created` means nothing was delivered, so revocation finalized at once.
    expect(f.status().status).toBe("timed_out");
    const response = await f.dispatch();
    expect(response.status).toBe(409);
    expect(types(await f.outbound())).not.toContain("assignment.start");
  });

  it("ignores a late provider start acknowledgement for a revoked assignment", async () => {
    const f = await revoked("acknowledged");
    await f.send("assignment.start.ack", started);
    await f.send("assignment.ack", { accepted: true });
    expect(f.status().status).toBe("revocation_pending");
  });

  it("re-sends the cancel with a stable command id when the Service syncs", async () => {
    const f = await revoked("running");
    await f.outbound();
    await f.send("workspace.sync.request", {});
    const first = (await f.outbound()).filter(
      (m) => m.type === "assignment.cancel",
    );
    expect(first).toHaveLength(1);
    expect(first[0]!.payload).toMatchObject({
      assignmentId: "A1",
      commandId: "revoke:A1:ATT1",
      reason: timeoutIntent.reason,
    });
    // A second reconnect re-sends the same command identity.
    await f.send("workspace.sync.request", {});
    const second = (await f.outbound()).filter(
      (m) => m.type === "assignment.cancel",
    );
    expect(second).toHaveLength(1);
    expect(second[0]!.payload).toMatchObject({ commandId: "revoke:A1:ATT1" });
    expect(f.status().status).toBe("revocation_pending");
  });

  it("reports an old unconfirmed revocation as reconciling in the sync result", async () => {
    const f = await revoked("running");
    f.sqlite
      .prepare("UPDATE worker_assignments SET updated_at=? WHERE id='A1'")
      .run("2026-10-14T09:00:00.000Z");
    await f.outbound();
    await f.send("workspace.sync.request", {});
    const messages = await f.outbound();
    const sync = messages.find((m) => m.type === "workspace.sync.result");
    expect(sync).toBeDefined();
    expect(f.status().status).toBe("reconciling");
    // Still being re-sent after the escalation.
    expect(types(messages)).toContain("assignment.cancel");
  });

  it("finalizes the intended outcome when the Service confirms the cancel", async () => {
    const f = await revoked("running");
    await f.send("assignment.cancel.ack", {
      cancelled: true,
      alreadyTerminated: false,
    });
    expect(f.status().status).toBe("timed_out");
    const task = f.sqlite
      .prepare("SELECT status FROM workflow_tasks WHERE id='T'")
      .get() as { status: string };
    expect(task.status).toBe("failed");
  });

  it("does not finalize on a cancel acknowledgement that says the stop failed", async () => {
    const f = await revoked("running");
    await f.send("assignment.cancel.ack", { cancelled: false });
    expect(f.status().status).toBe("revocation_pending");
  });

  it("treats the Service's own cancelled report as the stop confirmation", async () => {
    const f = await revoked("running");
    await f.send("assignment.cancelled", {
      status: "cancelled",
      reason: "Assignment cancelled before terminal completion.",
    });
    expect(f.status().status).toBe("timed_out");
  });

  it("still treats an unrequested cancellation as an ordinary cancellation", async () => {
    const f = await gatewayFixture("running");
    await f.send("assignment.cancelled", {
      status: "cancelled",
      reason: "User cancelled",
    });
    expect(f.status().status).toBe("cancelled");
  });

  it("accepts a result that arrives while the stop is outstanding", async () => {
    const f = await revoked("running");
    await f.send("assignment.result", {
      status: "completed",
      summary: "done",
      output: { text: "finished first" },
      artifactIds: [],
    });
    expect(f.status().status).toBe("completed");
  });
});

describe("Gateway start fencing", () => {
  function advertise(
    f: Awaited<ReturnType<typeof gatewayFixture>>,
    caps: string[],
  ) {
    f.sqlite
      .prepare(
        `INSERT INTO workspace_runtime_facts(workspace_id, runtime_capabilities_json, updated_at)
         VALUES('WS', ?, 'now')
         ON CONFLICT(workspace_id) DO UPDATE SET runtime_capabilities_json = excluded.runtime_capabilities_json`,
      )
      .run(JSON.stringify(caps));
  }
  const required = (f: Awaited<ReturnType<typeof gatewayFixture>>) =>
    (
      f.sqlite
        .prepare(
          "SELECT start_permit_required AS r FROM worker_assignments WHERE id='A1'",
        )
        .get() as { r: number }
    ).r;

  it("tells a permit-capable Service to request a permit, and remembers it", async () => {
    const f = await gatewayFixture("created");
    advertise(f, ["dart", START_PERMIT_CAPABILITY]);
    expect((await f.dispatch()).status).toBe(200);
    const start = (await f.outbound()).find(
      (m) => m.type === "assignment.start",
    );
    expect(start).toBeDefined();
    expect(
      (start!.payload as { snapshot: { startPermit?: unknown } }).snapshot
        .startPermit,
    ).toEqual({ required: true });
    expect(required(f)).toBe(1);
    // Redelivery keeps the requirement.
    await f.dispatch();
    const again = (await f.outbound()).find(
      (m) => m.type === "assignment.start",
    );
    expect(
      (again!.payload as { snapshot: { startPermit?: unknown } }).snapshot
        .startPermit,
    ).toEqual({ required: true });
  });

  it("does not require a permit from a Service that cannot request one", async () => {
    const f = await gatewayFixture("created");
    advertise(f, ["dart"]);
    expect((await f.dispatch()).status).toBe(200);
    const start = (await f.outbound()).find(
      (m) => m.type === "assignment.start",
    );
    expect(
      (start!.payload as { snapshot: Record<string, unknown> }).snapshot
        .startPermit,
    ).toBeUndefined();
    expect(required(f)).toBe(0);
  });

  it("answers a permit request with a grant while the assignment is live", async () => {
    const f = await gatewayFixture("acknowledged");
    await f.outbound();
    await f.send("assignment.start.permit.request", {});
    const grant = (await f.outbound()).find(
      (m) => m.type === "assignment.start.permit.grant",
    );
    expect(grant).toBeDefined();
    expect(grant!.payload).toMatchObject({ granted: true });
    expect(typeof (grant!.payload as { permitId: string }).permitId).toBe(
      "string",
    );
    expect(f.status().status).toBe("acknowledged");
  });

  it("denies the permit once Cloud has revoked the assignment, so a queued command cannot launch", async () => {
    const f = await gatewayFixture("acknowledged");
    f.sqlite.exec(
      "UPDATE worker_assignments SET start_permit_required = 1 WHERE id='A1'",
    );
    // The startup deadline passes while the command waits in the Service queue.
    const begun = await beginAssignmentRevocation(f.db as never, {
      assignmentId: "A1",
      attemptId: "ATT1",
      intent: timeoutIntent,
    });
    expect(begun).toMatchObject({ outcome: "finalized", fenced: true });
    expect(f.status().status).toBe("timed_out");
    await f.outbound();
    // The Service reaches the front of its queue and asks to start.
    await f.send("assignment.start.permit.request", {});
    const grant = (await f.outbound()).find(
      (m) => m.type === "assignment.start.permit.grant",
    );
    expect(grant!.payload).toEqual({ granted: false, reason: "terminal" });
    expect(f.status().status).toBe("timed_out");
  });

  it("denies a permit request for an assignment that is being revoked", async () => {
    const f = await revoked("running");
    await f.outbound();
    await f.send("assignment.start.permit.request", {});
    const grant = (await f.outbound()).find(
      (m) => m.type === "assignment.start.permit.grant",
    );
    expect(grant!.payload).toMatchObject({ granted: false });
  });
});
