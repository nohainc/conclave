import { describe, expect, it } from "vitest";
import { gatewayFixture } from "./helpers/assignment-gateway.js";

const payload = {
  snapshot: { workerTypeId: "chatgpt" },
  input: { objective: "waits for a free slot" },
};

/** One slot, already held by a running assignment B1. */
async function fullWorkspace() {
  const f = await gatewayFixture("created");
  f.sqlite.exec(`
    UPDATE execution_workspaces SET parallel_slots = 1 WHERE id = 'WS';
    CREATE TEMP TABLE occupant AS SELECT * FROM worker_assignments WHERE id = 'A1';
    UPDATE occupant SET id = 'B1', attempt_id = 'ATT2', idempotency_key = 'IDEM2', status = 'running';
    INSERT INTO worker_assignments SELECT * FROM occupant;
  `);
  f.sqlite
    .prepare(
      "UPDATE worker_assignments SET command_payload_json = ? WHERE id = 'A1'",
    )
    .run(JSON.stringify(payload));
  return f;
}

describe("Cloud-owned Workspace slots", () => {
  it("keeps work in the Cloud queue while every slot is taken", async () => {
    const f = await fullWorkspace();
    const response = await f.dispatch();
    expect(response.status).toBe(202);
    expect(await response.json()).toMatchObject({
      delivered: false,
      queued: true,
      deliveryState: "waiting_for_slot",
    });
    expect(f.status().status).toBe("created");
    expect(
      (await f.outbound()).filter((m) => m.type === "assignment.start"),
    ).toHaveLength(0);
  });

  it("starts queued work once a slot frees, stamped with the slot total", async () => {
    const f = await fullWorkspace();
    await f.dispatch();
    f.sqlite.exec(
      "UPDATE worker_assignments SET status = 'completed' WHERE id = 'B1'",
    );
    await f.gateway.fetch(
      new Request("https://gateway.internal/flush-queued", { method: "POST" }),
    );
    const started = (await f.outbound()).filter(
      (m) => m.type === "assignment.start",
    );
    expect(started).toHaveLength(1);
    expect(
      (started[0]!.payload.snapshot as Record<string, unknown>)
        .maxConcurrentAssignments,
    ).toBe(1);
    expect(f.status().status).toBe("dispatched");
  });
});
