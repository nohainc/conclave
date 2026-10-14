import { expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { conversationFixture } from "./helpers/conversation.js";
import {
  conversationWorkerSessionReference,
  recordAssignmentResult,
  recordAssignmentError,
  recordAssignmentCancelled,
} from "../src/assignment-dispatcher.js";

it("snapshots every actual invocation and links retries to the immutable original user message", async () => {
  const f = await conversationFixture();
  f.assign("A");
  const first = (await f.turns())[0]!;
  expect(first).toMatchObject({
    id: "turn-A",
    userMessageId: "message-user-R",
    workRequestId: "R",
    workflowId: "chat",
    workflowVersion: 1,
    workerId: "worker-a",
    workerTypeId: "chatgpt",
    workerDisplayName: "ChatGPT",
    profileId: "chatgpt-codex",
    profileVersion: 3,
    modelId: "model-x",
    effort: "medium",
    workerSessionId: "worker-session-opaque",
    baseContextRevision: 0,
    status: "queued",
    startedAt: null,
    completedAt: null,
  });
  expect(
    f.sqlite.prepare("SELECT text FROM conversation_user_messages").get()?.text,
  ).toBe("**Exact user text**");
  f.sqlite.exec(
    "UPDATE worker_catalog SET display_name = 'Renamed today' WHERE worker_type_id = 'chatgpt'",
  );
  expect((await f.turns())[0]).toEqual(first);
  f.assign("B", "model-y", "high");
  const records = await f.turns();
  expect(records).toHaveLength(2);
  expect(records[1]).toMatchObject({
    id: "turn-B",
    userMessageId: first.userMessageId,
    modelId: "model-y",
    effort: "high",
  });
  expect(() => f.assign("A")).toThrow();
  expect(() =>
    f.sqlite.exec("UPDATE conversation_turns SET model_id = 'new-model'"),
  ).toThrow("attribution is immutable");
  expect(() =>
    f.sqlite.exec("UPDATE conversation_user_messages SET text = 'changed'"),
  ).toThrow("messages are immutable");
  f.sqlite.close();
});

it("records start acknowledgement, exact terminal evidence, and prevents completion replay rewrites", async () => {
  const f = await conversationFixture();
  f.assign("A", null, null);
  f.start("A", "2026-10-07T10:02:00Z");
  expect((await f.turns())[0]).toMatchObject({
    status: "running",
    startedAt: "2026-10-07T10:02:00Z",
    modelId: null,
    effort: null,
  });
  await recordAssignmentResult(f.db as unknown as D1Database, "A", {
    assignmentId: "A",
    status: "completed",
    output: { text: "**Original reply**" },
    artifactIds: [],
    completedAt: "untrusted-provider-time",
  });
  const before = (await f.turns())[0]!;
  expect(before).toMatchObject({
    status: "completed",
    resultText: "**Original reply**",
    startedAt: "2026-10-07T10:02:00Z",
  });
  expect(before.completedAt).not.toBeNull();
  await recordAssignmentResult(f.db as unknown as D1Database, "A", {
    assignmentId: "A",
    status: "completed",
    output: { text: "rewritten" },
    artifactIds: [],
    completedAt: "later",
  });
  expect((await f.turns())[0]).toEqual(before);
  f.sqlite.exec("UPDATE worker_assignments SET status='running' WHERE id='A'");
  expect((await f.turns())[0]).toEqual(before);
  f.sqlite.close();
});

it("keeps admission queued and records provider start only from explicit evidence", async () => {
  const f = await conversationFixture();
  try {
    f.assign("A");
    f.sqlite.exec(
      "UPDATE worker_assignments SET status='acknowledged', acknowledged_at='admitted', updated_at='admitted' WHERE id='A'",
    );
    expect((await f.turns())[0]).toMatchObject({
      status: "queued",
      startedAt: null,
    });
    f.sqlite.exec(
      "UPDATE worker_assignments SET status='running', running_at='provider-start', updated_at='later' WHERE id='A'",
    );
    expect((await f.turns())[0]).toMatchObject({
      status: "running",
      startedAt: "provider-start",
    });
  } finally {
    f.sqlite.close();
  }
});

it.each(["completed", "failed", "cancelled", "timed_out", "lost"])(
  "projects terminal %s without inventing a provider start and ignores late evidence",
  async (status) => {
    const f = await conversationFixture();
    try {
      f.assign("A");
      f.sqlite
        .prepare(
          "UPDATE worker_assignments SET status=?, updated_at='terminal', output_json=? WHERE id='A'",
        )
        .run(status, JSON.stringify({ output: { text: "**exact**" } }));
      const turn = (await f.turns())[0]!;
      expect(turn).toMatchObject({
        status: ["timed_out", "lost"].includes(status) ? "failed" : status,
        startedAt: null,
        completedAt: "terminal",
        resultText: status === "completed" ? "**exact**" : null,
      });
      f.sqlite.exec(
        "UPDATE worker_assignments SET status='acknowledged',updated_at='late' WHERE id='A'",
      );
      expect((await f.turns())[0]).toEqual(turn);
      expect(() =>
        f.sqlite.exec(
          "UPDATE conversation_turns SET result_text='rewrite' WHERE assignment_id='A'",
        ),
      ).toThrow("lifecycle");
    } finally {
      f.sqlite.close();
    }
  },
);

it.each(["revocation_pending", "reconciling"])(
  "0062 repairs admission-only Running during %s without guessing ambiguous starts",
  async (status) => {
    const f = await conversationFixture({ beforeTurnLifecycleRepair: true });
    try {
      f.assign("known");
      f.assign("ambiguous");
      f.sqlite.exec(`
        UPDATE worker_assignments SET status='acknowledged', acknowledged_at='2026-10-14T10:00:00Z', updated_at='2026-10-14T10:00:00Z';
        UPDATE worker_assignments SET acknowledged_at=NULL WHERE id='ambiguous';
      `);
      f.sqlite
        .prepare(
          "UPDATE worker_assignments SET status=?, updated_at='2026-10-14T10:02:00Z'",
        )
        .run(status);
      f.sqlite.exec(
        readFileSync(
          new URL(
            "../migrations-v8/0062_conversation_turn_lifecycle.sql",
            import.meta.url,
          ),
          "utf8",
        ),
      );
      const turns = await f.turns();
      expect(turns.find((t) => t.assignmentId === "known")).toMatchObject({
        status: "queued",
        startedAt: null,
        completedAt: null,
      });
      expect(turns.find((t) => t.assignmentId === "ambiguous")).toMatchObject({
        status: "running",
        startedAt: "2026-10-14T10:00:00Z",
        completedAt: null,
      });
      expect(
        f.sqlite
          .prepare("SELECT status FROM worker_assignments WHERE id='known'")
          .get()?.status,
      ).toBe(status);
    } finally {
      f.sqlite.close();
    }
  },
);

it.each(["running", "revocation_pending", "reconciling"])(
  "0062 advances a proven admission-derived start to provider time while %s",
  async (status) => {
    const f = await conversationFixture({ beforeTurnLifecycleRepair: true });
    try {
      for (const id of ["known", "ambiguous", "terminal"]) f.assign(id);
      f.sqlite.exec(`
        UPDATE worker_assignments SET status='acknowledged', acknowledged_at='2026-10-14T10:00:00Z', updated_at='2026-10-14T10:00:00Z';
        UPDATE worker_assignments SET acknowledged_at=NULL WHERE id='ambiguous';
        UPDATE worker_assignments SET status='running', running_at='2026-10-14T10:01:00Z', updated_at='2026-10-14T10:01:00Z';
        UPDATE worker_assignments SET status='completed', updated_at='2026-10-14T10:02:00Z', output_json='{"output":{"text":"original"}}' WHERE id='terminal';
      `);
      const terminal = f.sqlite
        .prepare(
          "SELECT * FROM conversation_turns WHERE assignment_id='terminal'",
        )
        .get();
      f.sqlite
        .prepare(
          "UPDATE worker_assignments SET status=?, updated_at='2026-10-14T10:03:00Z' WHERE id != 'terminal'",
        )
        .run(status);
      f.sqlite.exec(
        readFileSync(
          new URL(
            "../migrations-v8/0062_conversation_turn_lifecycle.sql",
            import.meta.url,
          ),
          "utf8",
        ),
      );
      const turns = await f.turns();
      expect(turns.find((t) => t.assignmentId === "known")).toMatchObject({
        status: "running",
        startedAt: "2026-10-14T10:01:00Z",
        completedAt: null,
      });
      expect(turns.find((t) => t.assignmentId === "ambiguous")).toMatchObject({
        status: "running",
        startedAt: "2026-10-14T10:00:00Z",
        completedAt: null,
      });
      expect(
        f.sqlite
          .prepare(
            "SELECT * FROM conversation_turns WHERE assignment_id='terminal'",
          )
          .get(),
      ).toEqual(terminal);
    } finally {
      f.sqlite.close();
    }
  },
);

it("0062 repairs only nonterminal projections and preserves terminal history and attribution", async () => {
  const f = await conversationFixture({ beforeTurnLifecycleRepair: true });
  try {
    for (const id of ["admission", "timeout", "lost", "complete", "unknown"])
      f.assign(id);
    f.sqlite.exec(`
      UPDATE worker_assignments SET status='acknowledged', acknowledged_at='admission', updated_at='admission';
      UPDATE worker_assignments SET status='timed_out', updated_at='timeout-end' WHERE id='timeout';
      UPDATE worker_assignments SET status='lost', updated_at='lost-end' WHERE id='lost';
      UPDATE worker_assignments SET status='completed', updated_at='complete-end', output_json='{"output":{"text":"original"}}' WHERE id='complete';
      UPDATE worker_assignments SET status='timed_out', updated_at='later' WHERE id='complete';
      UPDATE worker_assignments SET acknowledged_at=NULL, updated_at='different' WHERE id='unknown';
    `);
    const before = f.sqlite
      .prepare(
        "SELECT * FROM conversation_turns WHERE assignment_id='complete'",
      )
      .get();
    const attribution = f.sqlite
      .prepare(
        "SELECT id, assignment_id, worker_id, profile_id, model_id, created_at FROM conversation_turns ORDER BY id",
      )
      .all();
    f.sqlite.exec(
      readFileSync(
        new URL(
          "../migrations-v8/0062_conversation_turn_lifecycle.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    const turns = await f.turns();
    expect(turns.find((t) => t.assignmentId === "admission")).toMatchObject({
      status: "queued",
      startedAt: null,
    });
    expect(turns.find((t) => t.assignmentId === "timeout")).toMatchObject({
      status: "failed",
      completedAt: "timeout-end",
    });
    expect(turns.find((t) => t.assignmentId === "lost")).toMatchObject({
      status: "failed",
      completedAt: "lost-end",
    });
    expect(turns.find((t) => t.assignmentId === "unknown")).toMatchObject({
      status: "running",
      startedAt: "admission",
    });
    expect(
      f.sqlite
        .prepare(
          "SELECT * FROM conversation_turns WHERE assignment_id='complete'",
        )
        .get(),
    ).toEqual(before);
    expect(
      f.sqlite
        .prepare(
          "SELECT id, assignment_id, worker_id, profile_id, model_id, created_at FROM conversation_turns ORDER BY id",
        )
        .all(),
    ).toEqual(attribution);
  } finally {
    f.sqlite.close();
  }
});

it.each(["failed", "cancelled"] as const)(
  "retains a terminal %s attempt independently of a subsequent retry",
  async (status) => {
    const f = await conversationFixture();
    f.assign("A");
    if (status === "failed")
      await recordAssignmentError(f.db as unknown as D1Database, "A", {
        error: {
          code: "execution_failed",
          message: "failure",
          retryable: true,
        },
        failedAt: "now",
      });
    else
      await recordAssignmentCancelled(f.db as unknown as D1Database, "A", {
        status: "cancelled",
        reason: "User cancelled",
      });
    const original = (await f.turns())[0]!;
    expect(original.status).toBe(status);
    expect(original.completedAt).not.toBeNull();
    f.assign("B");
    expect((await f.turns())[0]).toEqual(original);
    f.sqlite.close();
  },
);

it("creates no worker turn before actual dispatch and rolls invalid attribution back atomically", async () => {
  const f = await conversationFixture();
  expect(await f.turns()).toEqual([]);
  expect(() =>
    f.sqlite.exec(
      `INSERT INTO worker_assignments(id,space_id,execution_workspace_id,runtime_identity_id,worker_type_id,workspace_worker_id,task_id,status,created_at,updated_at) VALUES('invalid','P','WS','RT','chatgpt','worker-a','T','created','now','now')`,
    ),
  ).toThrow();
  expect(
    f.sqlite
      .prepare(
        "SELECT count(*) AS n FROM worker_assignments WHERE id='invalid'",
      )
      .get()?.n,
  ).toBe(0);
  f.sqlite.close();
});

it("opaque session references are stable per scope and never expose logical keys", () => {
  const target = {
    workspaceId: "WS",
    workerId: "worker-a",
    profileDefinitionId: "profile-a",
    profileReleaseVersion: 3,
  };
  const id = conversationWorkerSessionReference(
    target,
    "durable_session",
    "logical-private-key",
  );
  expect(id).toMatch(/^worker-session-[a-f0-9]{64}$/);
  expect(
    conversationWorkerSessionReference(
      target,
      "durable_session",
      "logical-private-key",
    ),
  ).toBe(id);
  expect(
    conversationWorkerSessionReference(
      { ...target, workerId: "worker-b" },
      "durable_session",
      "logical-private-key",
    ),
  ).not.toBe(id);
  expect(
    conversationWorkerSessionReference(target, "durable_session", "fresh-key"),
  ).not.toBe(id);
  expect(
    conversationWorkerSessionReference(
      target,
      "stateless",
      "logical-private-key",
    ),
  ).toBeNull();
});

it("stateless turns have no durable worker-session reference", async () => {
  const f = await conversationFixture();
  f.assign("S", null, null, "stateless");
  expect((await f.turns())[0]!.workerSessionId).toBeNull();
  f.sqlite.close();
});

it("session identity survives model choices and compatible Profile release changes", () => {
  const base = {
    workspaceId: "WS",
    workerId: "worker-A",
    profileDefinitionId: "profile-A",
    conversationId: "conversation-A",
    profileReleaseVersion: 1,
    model: "model-A",
    effort: "medium",
  };
  const id = conversationWorkerSessionReference(
    base,
    "durable_session",
    "scope-A",
  );
  const changedOptions = {
    ...base,
    profileReleaseVersion: 2,
    model: "model-B",
    effort: "high",
  };
  expect(
    conversationWorkerSessionReference(
      changedOptions,
      "durable_session",
      "scope-A",
    ),
  ).toBe(id);
  expect(
    conversationWorkerSessionReference(
      { ...base, conversationId: "conversation-B" },
      "durable_session",
      "scope-A",
    ),
  ).not.toBe(id);
});

it("preserves the dispatched context revision when the Conversation advances before assignment insertion", async () => {
  const f = await conversationFixture();
  f.sqlite.exec("UPDATE conversations SET context_revision = 1");
  f.assign("A-frozen", "model-x", "medium", "durable_session", 0);
  expect((await f.turns())[0]!.baseContextRevision).toBe(0);
});

it("effort changes preserve Conversation and Worker Session while freezing each turn's effort", async () => {
  const f = await conversationFixture();
  f.assign("effort-medium", "model-x", "medium");
  f.assign("effort-high", "model-x", "high");
  const [first, second] = await f.turns();
  expect(first!.conversationId).toBe(second!.conversationId);
  expect(first!.workerSessionId).toBe(second!.workerSessionId);
  expect(first!.modelId).toBe(second!.modelId);
  expect(first!.effort).toBe("medium");
  expect(second!.effort).toBe("high");
  expect(
    f.sqlite.prepare("SELECT count(*) AS n FROM conversations").get(),
  ).toEqual({ n: 1 });
  f.sqlite.close();
});

it("next-request defaults do not rewrite completed turn attribution or create extra Chat steps", async () => {
  const f = await conversationFixture();
  try {
    f.assign("original", "model-x", "medium");
    f.start("original");
    await recordAssignmentResult(f.db as unknown as D1Database, "original", {
      assignmentId: "original",
      status: "completed",
      output: { text: "Original answer" },
      artifactIds: [],
      completedAt: "now",
    });
    const before = (await f.turns())[0];
    f.sqlite
      .prepare(
        "INSERT INTO thread_work_configs(thread_id,config_json,updated_at) VALUES('W',?,'later')",
      )
      .run(
        JSON.stringify({
          bindings: {
            chat: {
              workerId: "gemini",
              model: "model-y",
              reasoningEffort: "high",
            },
          },
        }),
      );
    expect((await f.turns())[0]).toEqual(before);
    expect(before).toMatchObject({
      modelId: "model-x",
      effort: "medium",
      status: "completed",
    });
    expect(
      f.sqlite
        .prepare(
          "SELECT count(*) AS n FROM conversation_workflow_runs WHERE work_request_id='R'",
        )
        .get(),
    ).toEqual({ n: 1 });
    expect(
      f.sqlite
        .prepare(
          "SELECT count(*) AS n FROM conversation_workflow_step_runs WHERE workflow_run_id='workflow-run-R'",
        )
        .get(),
    ).toEqual({ n: 1 });
  } finally {
    f.sqlite.close();
  }
});

it("freezes friendly selection labels and catalog identity despite later inventory changes", async () => {
  const f = await conversationFixture();
  const snapshot = {
    schemaVersion: 1,
    workerTypeId: "chatgpt",
    workerDisplayName: "Original Worker",
    modelId: "model-x",
    modelName: "Original Model",
    effort: "medium",
    profileReleaseVersion: 3,
    catalogRevision: "a".repeat(64),
  };
  f.assign(
    "FROZEN",
    "model-x",
    "medium",
    "durable_session",
    undefined,
    undefined,
    snapshot,
  );
  f.start("FROZEN");
  const original = (await f.turns())[0]!;
  expect(original).toMatchObject({
    modelName: "Original Model",
    workerDisplayName: "Original Worker",
    catalogRevision: snapshot.catalogRevision,
  });
  f.sqlite.exec(
    "UPDATE worker_catalog SET display_name='New Worker' WHERE worker_type_id='chatgpt'",
  );
  expect((await f.turns())[0]).toEqual(original);
  expect(() =>
    f.sqlite.exec(
      "UPDATE worker_assignments SET permission_snapshot_json=json_set(permission_snapshot_json,'$.executionSelection.modelName','Changed') WHERE id='FROZEN'",
    ),
  ).toThrow("selection is immutable");
  expect(() =>
    f.sqlite.exec(
      "UPDATE worker_assignments SET model='new-model' WHERE id='FROZEN'",
    ),
  ).toThrow("selection is immutable");
  await recordAssignmentResult(f.db as unknown as D1Database, "FROZEN", {
    assignmentId: "FROZEN",
    completedAt: "2026-10-11T00:00:00Z",
    status: "completed",
    output: { text: "Reply" },
    artifactIds: [],
  });
  expect((await f.turns())[0]).toMatchObject({
    modelName: "Original Model",
    status: "completed",
  });
  f.sqlite.close();
});
