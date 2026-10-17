import { describe, expect, it } from "vitest";
import {
  applyEngineLivenessReport,
  failLostEngineAssignments,
  parseEngineLivenessReport,
} from "../src/assignment-liveness.js";
import { conversationFixture } from "./helpers/conversation.js";

const NOW = "2026-10-17T10:00:00.000Z";

async function seed(status = "running") {
  const f = await conversationFixture();
  f.sqlite.exec(
    "INSERT INTO runs(id,space_id,status,created_at,updated_at) VALUES('RUN','P','running','now','now')",
  );
  f.assign("A1");
  f.sqlite
    .prepare(
      `UPDATE worker_assignments
          SET run_id='RUN', attempt_id='ATT1', idempotency_key='IDEM1',
              status=?, updated_at=? WHERE id='A1'`,
    )
    .run(status, NOW);
  const workspaceId = (
    f.sqlite
      .prepare(
        "SELECT execution_workspace_id AS w FROM worker_assignments WHERE id='A1'",
      )
      .get() as { w: string }
  ).w;
  const status_ = () =>
    (
      f.sqlite
        .prepare("SELECT status FROM worker_assignments WHERE id='A1'")
        .get() as { status: string }
    ).status;
  return { f, workspaceId, status: status_ };
}

const report = (live: string[], pending: string[] = []) => ({
  liveAssignmentIds: new Set(live),
  pendingTerminalAssignmentIds: new Set(pending),
});

describe("engine liveness", () => {
  it("ignores heartbeats from a Service that does not report liveness", () => {
    expect(parseEngineLivenessReport({ status: "online" })).toBeNull();
    expect(
      parseEngineLivenessReport({ liveAssignmentIds: ["A1", 3, ""] })
        ?.liveAssignmentIds,
    ).toEqual(new Set(["A1"]));
  });

  it("waits for repeated missing reports before declaring the Engine lost", async () => {
    const { f, workspaceId } = await seed();
    const first = await applyEngineLivenessReport(
      f.db as never,
      workspaceId,
      report([]),
      NOW,
    );
    expect(first).toEqual([]);
    const second = await applyEngineLivenessReport(
      f.db as never,
      workspaceId,
      report([]),
      NOW,
    );
    expect(second.map((l) => l.assignmentId)).toEqual(["A1"]);
  });

  it("resets the count when the process is reported again", async () => {
    const { f, workspaceId } = await seed();
    await applyEngineLivenessReport(
      f.db as never,
      workspaceId,
      report([]),
      NOW,
    );
    await applyEngineLivenessReport(
      f.db as never,
      workspaceId,
      report(["A1"]),
      NOW,
    );
    const lost = await applyEngineLivenessReport(
      f.db as never,
      workspaceId,
      report([]),
      NOW,
    );
    expect(lost).toEqual([]);
  });

  it("treats an unacknowledged journal outcome as present", async () => {
    const { f, workspaceId } = await seed();
    for (let i = 0; i < 4; i += 1) {
      const lost = await applyEngineLivenessReport(
        f.db as never,
        workspaceId,
        report([], ["A1"]),
        NOW,
      );
      expect(lost).toEqual([]);
    }
  });

  it("starts a revocation for a lost Engine", async () => {
    const { f, workspaceId, status } = await seed();
    await applyEngineLivenessReport(
      f.db as never,
      workspaceId,
      report([]),
      NOW,
    );
    const lost = await applyEngineLivenessReport(
      f.db as never,
      workspaceId,
      report([]),
      NOW,
    );
    expect(await failLostEngineAssignments(f.db as never, lost, NOW)).toBe(1);
    expect(status()).not.toBe("running");
  });

  it("does not touch assignments that are not running", async () => {
    const { f, workspaceId } = await seed("dispatched");
    for (let i = 0; i < 3; i += 1) {
      expect(
        await applyEngineLivenessReport(
          f.db as never,
          workspaceId,
          report([]),
          NOW,
        ),
      ).toEqual([]);
    }
  });
});
