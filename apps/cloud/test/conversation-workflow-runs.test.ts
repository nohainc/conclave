import { expect, it } from "vitest";
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { conversationFixture } from "./helpers/conversation.js";
import { loadConversationWorkflowRuns } from "../src/routes/conversation-workflow-runs.js";

it("one user message owns a WorkflowRun with multiple Worker turns and runtime attempts", async () => {
  const f = await conversationFixture();
  try {
    f.sqlite
      .exec(`INSERT INTO runs(id,project_id,workstream_id,work_request_id,status,created_at,updated_at) VALUES
      ('RUN1','P','W','R','failed','1','1'), ('RUN2','P','W','R','running','2','2');`);
    const pending = (
      await loadConversationWorkflowRuns(f.db as unknown as D1Database, ["R"])
    ).get("R")!;
    expect(pending.workerTurnIds).toEqual([]);
    expect(pending.stepRuns).toHaveLength(1);
    expect(pending.triggerMessageId).toBe(pending.userMessageId);
    expect(() =>
      f.sqlite.exec(
        "INSERT INTO conversation_workflow_runs(id,conversation_id,user_message_id,work_request_id,workflow_id,workflow_version,created_at) SELECT 'foreign-run',conversation_id,user_message_id,work_request_id,'direct',2,created_at FROM conversation_workflow_runs",
      ),
    ).toThrow(/scoped user message/);
    f.assign("A");
    f.assign("B", "model-y", "high");
    f.sqlite
      .exec(`INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,created_at,updated_at)
      VALUES('VERIFY','R','verify','stateless_read',1000,'verify:v1','queued','now','now');
      INSERT INTO worker_assignments(id,project_id,execution_workspace_id,runtime_identity_id,worker_type_id,workspace_worker_id,task_id,run_id,status,permission_snapshot_json,created_at,updated_at)
      VALUES('V','P','WS','RT','gemini','worker-gemini','VERIFY','RUN2','created','{"profileDefinitionId":"gemini-antigravity","profileReleaseVersion":1,"workerDisplayName":"Gemini"}','now','now');`);
    const run = (
      await loadConversationWorkflowRuns(f.db as unknown as D1Database, ["R"])
    ).get("R")!;
    expect(run).toMatchObject({
      schemaVersion: 1,
      id: "workflow-run-R",
      userMessageId: "message-user-R",
      workRequestId: "R",
      status: "running",
      runtimeRunIds: ["RUN1", "RUN2"],
      workerTurnIds: ["turn-A", "turn-B", "turn-V"],
    });
    expect(run.stepRuns).toHaveLength(2);
    expect(
      run.stepRuns.find((step) => step.stepId === "chat")?.workerTurnIds,
    ).toEqual(["turn-A", "turn-B"]);
    expect(run.stepRuns.find((step) => step.stepId === "verify")).toMatchObject(
      {
        id: "step-run-VERIFY",
        workflowRunId: run.id,
        role: "verify",
        workerId: "worker-gemini",
      },
    );
    const turns = await f.turns();
    expect(new Set(turns.map((turn) => turn.workflowRunId))).toEqual(
      new Set([run.id]),
    );
    expect(new Set(turns.map((turn) => turn.userMessageId))).toEqual(
      new Set([run.userMessageId]),
    );
    expect(turns[2]).toMatchObject({
      runtimeRunId: "RUN2",
      stepKind: "verify",
      workerTypeId: "gemini",
    });
    expect(() =>
      f.sqlite.exec(
        "UPDATE conversation_turns SET workflow_run_id='foreign' WHERE id='turn-A'",
      ),
    ).toThrow(/immutable/);
    expect(() =>
      f.sqlite.exec(
        "UPDATE conversation_workflow_runs SET user_message_id='foreign'",
      ),
    ).toThrow(/immutable/);
    f.sqlite.exec(
      "UPDATE work_requests SET status='completed',updated_at='later' WHERE id='R'",
    );
    const completed = (
      await loadConversationWorkflowRuns(f.db as unknown as D1Database, ["R"])
    ).get("R")!;
    expect(completed.status).toBe("completed");
    expect(completed.workerTurnIds).toEqual(run.workerTurnIds);
    expect(
      (
        await loadConversationWorkflowRuns(f.db as unknown as D1Database, [
          "missing",
        ])
      ).size,
    ).toBe(0);
  } finally {
    f.sqlite.close();
  }
});

it("backfills WorkflowRun ownership without rewriting historical turn evidence", () => {
  const db = new DatabaseSync(":memory:");
  try {
    for (const file of [
      "0001_conclave_v8.sql",
      "0006_chat_workflow_admission.sql",
      "0009_realtime_stream_alignment.sql",
      "0010_conversation_workflows.sql",
      "0011_conversation_turns.sql",
      "0012_canonical_conversation_history.sql",
      "0013_worker_session_context.sql",
      "0014_exact_history_context.sql",
    ])
      db.exec(
        readFileSync(
          new URL(`../migrations-v8/${file}`, import.meta.url),
          "utf8",
        ),
      );
    db.exec(`PRAGMA foreign_keys=ON;
      INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('U','u@test','User','now','now');
      INSERT INTO projects(id,owner_user_id,name,created_at,updated_at) VALUES('P','U','Project','now','now');
      INSERT INTO workstreams(id,project_id,name,status,lead_user_id,created_at,updated_at) VALUES('W','P','Stream','active','U','now','now');
      INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES('WS','U','Workspace','now','now');
      INSERT INTO workspace_runtime_identities(id,workspace_id,credential_token_hash,installation_id,created_at) VALUES('RT','WS','hash','installation','now');
      INSERT INTO work_requests(id,workstream_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at) VALUES('R','W','U','stateless','chat',1,'{}','running','{"originalRequest":"Original message"}','now','now');
      INSERT INTO conversations(id,workstream_id,workflow_id,workflow_version,conversation_revision,context_revision,created_at,updated_at) VALUES('C','W','chat',1,1,1,'now','now');
      INSERT INTO conversation_work_requests VALUES('C','R',1);
      INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,created_at,updated_at) VALUES('T','R','chat','stateless_read',1000,'chat:v1','running','now','now');
      INSERT INTO worker_assignments(id,project_id,execution_workspace_id,runtime_identity_id,worker_type_id,workspace_worker_id,task_id,status,permission_snapshot_json,created_at,updated_at) VALUES('A','P','WS','RT','chatgpt','worker-a','T','created','{"profileDefinitionId":"chatgpt-codex","profileReleaseVersion":1}','now','now');
      UPDATE worker_assignments SET output_json='{"output":{"text":"Exact answer"}}',status='completed',updated_at='later' WHERE id='A';`);
    const before = db.prepare("SELECT * FROM conversation_turns").get();
    const historyBefore = db
      .prepare("SELECT * FROM conversation_history_entries ORDER BY sequence")
      .all();
    db.exec(
      readFileSync(
        new URL(
          "../migrations-v8/0015_conversation_workflow_runs.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    const after = db.prepare("SELECT * FROM conversation_turns").get()!;
    expect(after.workflow_run_id).toBe("workflow-run-R");
    const { workflow_run_id: _run, ...rest } = after;
    expect(rest).toEqual(before);
    expect(
      db
        .prepare("SELECT * FROM conversation_history_entries ORDER BY sequence")
        .all(),
    ).toEqual(historyBefore);
    expect(
      db.prepare("SELECT user_message_id FROM conversation_workflow_runs").get()
        ?.user_message_id,
    ).toBe("message-user-R");
    const phase18Turn = db.prepare("SELECT * FROM conversation_turns").get();
    db.exec(
      "UPDATE workflow_tasks SET status='completed',finished_at='later' WHERE id='T'; UPDATE work_requests SET status='completed',updated_at='later' WHERE id='R'",
    );
    const phase18History = db
      .prepare("SELECT * FROM conversation_history_entries ORDER BY sequence")
      .all();
    db.exec(
      readFileSync(
        new URL(
          "../migrations-v8/0016_workflow_step_runs.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    const phase19Turn = db.prepare("SELECT * FROM conversation_turns").get()!;
    const { workflow_step_run_id: stepRunId, ...turnEvidence } = phase19Turn;
    expect(stepRunId).toBe("step-run-T");
    expect(turnEvidence).toEqual(phase18Turn);
    expect(
      db
        .prepare(
          "SELECT workflow_run_id,step_id,role FROM conversation_workflow_step_runs",
        )
        .get(),
    ).toMatchObject({
      workflow_run_id: "workflow-run-R",
      step_id: "chat",
      role: "chat",
    });
    expect(
      db.prepare("SELECT completed_at FROM conversation_workflow_runs").get()
        ?.completed_at,
    ).toBe("later");
    expect(
      db
        .prepare("SELECT * FROM conversation_history_entries ORDER BY sequence")
        .all(),
    ).toEqual(phase18History);
    expect(db.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
  } finally {
    db.close();
  }
});
