import { expect, it } from "vitest";
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
  f.sqlite.exec(
    "UPDATE worker_assignments SET status='acknowledged', updated_at='2026-10-07T10:02:00Z' WHERE id='A'",
  );
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
  expect(() =>
    f.sqlite.exec(
      "UPDATE worker_assignments SET status='running' WHERE id='A'",
    ),
  ).toThrow("lifecycle");
  f.sqlite.close();
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
      `INSERT INTO worker_assignments(id,project_id,execution_workspace_id,runtime_identity_id,worker_type_id,workspace_worker_id,task_id,status,created_at,updated_at) VALUES('invalid','P','WS','RT','chatgpt','worker-a','T','created','now','now')`,
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
        "INSERT INTO workstream_work_configs(workstream_id,config_json,updated_at) VALUES('W',?,'later')",
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
