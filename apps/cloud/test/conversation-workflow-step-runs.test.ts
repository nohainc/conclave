import { expect, it } from "vitest";
import { CONVERSATION_WORKFLOWS } from "@conclave/core";
import { conversationFixture } from "./helpers/conversation.js";
import { conversationSubmissionStatements } from "../src/routes/conversations.js";
import { loadConversationWorkflowRuns } from "../src/routes/conversation-workflow-runs.js";
import {
  recordAssignmentError,
  recordAssignmentResult,
} from "../src/assignment-dispatcher.js";

it("one Work StepRun snapshots pending choices and projects actual provider defaults without guessing", async () => {
  const f = await conversationFixture();
  try {
    const snapshot = JSON.stringify({
      resolvedBindings: {
        direct: {
          workerId: "configured-worker",
          model: "configured-model",
          reasoningEffort: "high",
        },
      },
    });
    f.sqlite
      .prepare(
        `INSERT INTO work_requests(id,workstream_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,snapshot_json,status,input_json,created_at,updated_at)
    VALUES('WORK','W','U','stateful','direct',2,'{}',?,'queued','{}','now','now')`,
      )
      .run(snapshot);
    await f.db.batch(
      conversationSubmissionStatements(
        f.db as unknown as D1Database,
        "W",
        CONVERSATION_WORKFLOWS.work!,
        "WORK",
        "now",
      ),
    );
    f.sqlite.exec(
      `INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,created_at,updated_at) VALUES('IMPLEMENT','WORK','implement','stateful_workstream',1000,'implement:v1','queued','now','now')`,
    );
    const pending = (
      await loadConversationWorkflowRuns(f.db as unknown as D1Database, [
        "WORK",
      ])
    ).get("WORK")!;
    expect(pending.stepRuns).toHaveLength(1);
    expect(
      f.sqlite
        .prepare(
          "SELECT count(*) AS n FROM conversation_workflow_runs WHERE work_request_id='WORK'",
        )
        .get(),
    ).toEqual({ n: 1 });
    expect(pending.stepRuns[0]).toMatchObject({
      id: "step-run-IMPLEMENT",
      stepId: "implement",
      role: "implement",
      workerId: "configured-worker",
      modelId: "configured-model",
      effort: "high",
      status: "queued",
      workerSessionId: null,
      baseContextRevision: 0,
      result: null,
    });
    f.sqlite
      .exec(`INSERT INTO worker_assignments(id,project_id,execution_workspace_id,runtime_identity_id,worker_type_id,workspace_worker_id,task_id,status,session_policy,permission_snapshot_json,created_at,updated_at)
    VALUES('WORKER','P','WS','RT','chatgpt','actual-worker','IMPLEMENT','created','durable_session','{"profileDefinitionId":"chatgpt-codex","profileReleaseVersion":1,"workerSessionId":"logical-session"}','now','now')`);
    const actual = (
      await loadConversationWorkflowRuns(f.db as unknown as D1Database, [
        "WORK",
      ])
    ).get("WORK")!.stepRuns[0]!;
    expect(actual).toMatchObject({
      workerId: "actual-worker",
      modelId: null,
      effort: null,
      workerSessionId: "logical-session",
      workerTurnIds: ["turn-WORKER"],
    });
    expect(() =>
      f.sqlite.exec(
        "UPDATE conversation_workflow_step_runs SET role='verify' WHERE id='step-run-IMPLEMENT'",
      ),
    ).toThrow(/immutable/);
    expect(() =>
      f.sqlite.exec(
        "UPDATE conversation_turns SET workflow_step_run_id='step-run-T' WHERE id='turn-WORKER'",
      ),
    ).toThrow(/immutable/);
    expect(() =>
      f.sqlite.exec(
        "INSERT INTO conversation_workflow_step_runs(id,workflow_run_id,task_id,step_id,role,created_at) VALUES('foreign','workflow-run-R','IMPLEMENT','implement','implement','now')",
      ),
    ).toThrow(/scoped/);
  } finally {
    f.sqlite.close();
  }
});

it("retries retain one StepRun and first-start evidence while clearing stale terminal results", async () => {
  const f = await conversationFixture();
  try {
    f.assign("A");
    f.sqlite.exec(
      "UPDATE workflow_tasks SET started_at='first-start' WHERE id='T'",
    );
    await recordAssignmentError(f.db as unknown as D1Database, "A", {
      error: { code: "execution_failed", message: "failure", retryable: true },
      failedAt: "failed",
    });
    f.sqlite.exec(
      "UPDATE work_requests SET status='failed',updated_at='failed-time' WHERE id='R'",
    );
    const failed = (
      await loadConversationWorkflowRuns(f.db as unknown as D1Database, ["R"])
    ).get("R")!;
    expect(failed.completedAt).toBe("failed-time");
    expect(failed.stepRuns[0]?.status).toBe("failed");
    const firstStart = failed.startedAt;
    f.sqlite.exec(
      "UPDATE work_requests SET status='queued',updated_at='retry-time' WHERE id='R'; UPDATE workflow_tasks SET status='queued',output_json=NULL,started_at=NULL,finished_at=NULL WHERE id='T'",
    );
    const queued = (
      await loadConversationWorkflowRuns(f.db as unknown as D1Database, ["R"])
    ).get("R")!;
    expect(queued.completedAt).toBeNull();
    expect(queued.stepRuns[0]?.result).toBeNull();
    f.assign("B", "model-y", "high");
    f.sqlite.exec(
      "UPDATE work_requests SET status='running',updated_at='second-start' WHERE id='R'",
    );
    await recordAssignmentResult(f.db as unknown as D1Database, "B", {
      assignmentId: "B",
      status: "completed",
      output: { text: "New successful result" },
      artifactIds: [],
      completedAt: "untrusted",
    });
    f.sqlite.exec(
      "UPDATE work_requests SET status='completed',updated_at='completed-time' WHERE id='R'",
    );
    const completed = (
      await loadConversationWorkflowRuns(f.db as unknown as D1Database, ["R"])
    ).get("R")!;
    expect(completed.startedAt).toBe(firstStart);
    expect(completed.completedAt).toBe("completed-time");
    expect(completed.stepRuns).toHaveLength(1);
    expect(completed.stepRuns[0]).toMatchObject({
      id: failed.stepRuns[0]!.id,
      modelId: "model-y",
      effort: "high",
      status: "completed",
      result: "New successful result",
      workerTurnIds: ["turn-A", "turn-B"],
    });
    expect((await f.turns())[0]?.status).toBe("failed");
    f.sqlite.exec(
      "UPDATE work_requests SET updated_at='unrelated-metadata-time' WHERE id='R'",
    );
    expect(
      (
        await loadConversationWorkflowRuns(f.db as unknown as D1Database, ["R"])
      ).get("R")!.completedAt,
    ).toBe("completed-time");
    expect(() =>
      f.sqlite.exec(
        "UPDATE conversation_workflow_runs SET started_at='rewritten'",
      ),
    ).toThrow(/immutable/);
  } finally {
    f.sqlite.close();
  }
});

it("StepRun and immutable turns retain their accepted context boundary as the Conversation advances", async () => {
  const f = await conversationFixture();
  try {
    const read = async () =>
      (
        await loadConversationWorkflowRuns(f.db as unknown as D1Database, ["R"])
      ).get("R")!.stepRuns[0]!;
    expect((await read()).baseContextRevision).toBe(0);
    f.sqlite.exec(
      "UPDATE conversations SET conversation_revision=104,context_revision=104",
    );
    expect(() =>
      f.assign("wrong-revision", "model-x", "medium", "durable_session", 104),
    ).toThrow(/context revision.*boundary/);
    expect(
      f.sqlite
        .prepare(
          "SELECT count(*) AS n FROM worker_assignments WHERE id='wrong-revision'",
        )
        .get(),
    ).toEqual({ n: 0 });
    f.assign("frozen-revision", "model-x", "medium", "durable_session", 0);
    await recordAssignmentResult(
      f.db as unknown as D1Database,
      "frozen-revision",
      {
        assignmentId: "frozen-revision",
        status: "completed",
        output: { text: "Result" },
        artifactIds: [],
        completedAt: "later",
      },
    );
    expect((await read()).baseContextRevision).toBe(0);
    expect((await f.turns())[0]!.baseContextRevision).toBe(0);
    expect(() =>
      f.sqlite.exec(
        "UPDATE conversation_turns SET base_context_revision=104 WHERE assignment_id='frozen-revision'",
      ),
    ).toThrow(/immutable/);
  } finally {
    f.sqlite.close();
  }
});
