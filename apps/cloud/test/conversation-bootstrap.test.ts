import { expect, it } from "vitest";
import { CONVERSATION_WORKFLOWS } from "@conclave/core";
import { conversationFixture } from "./helpers/conversation.js";
import { conversationSubmissionStatements } from "../src/routes/conversations.js";
import { loadConversationBootstrap } from "../src/routes/conversation-bootstrap.js";
import { recordAssignmentResult } from "../src/assignment-dispatcher.js";

it("includes late prior replies while excluding the current request", async () => {
  const f = await conversationFixture();
  try {
    f.assign("A");
    f.sqlite
      .exec(`INSERT INTO work_requests(id,workstream_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at)
      VALUES('R2','W','U','stateless','chat',1,'{}','running','{"originalRequest":"Current request"}','now','now')`);
    await f.db.batch(
      conversationSubmissionStatements(
        f.db as unknown as D1Database,
        "W",
        CONVERSATION_WORKFLOWS.chat!,
        "R2",
        "now",
      ),
    );
    await recordAssignmentResult(f.db as unknown as D1Database, "A", {
      assignmentId: "A",
      status: "completed",
      output: { text: "Previous answer" },
      artifactIds: [],
      completedAt: "2026-10-07T10:02:00Z",
    });
    const conversation = f.sqlite
      .prepare("SELECT id FROM conversations")
      .get() as { id: string };
    const bootstrap = await loadConversationBootstrap(
      f.db as unknown as D1Database,
      conversation.id,
      "R2",
      1,
    );
    const history = JSON.parse(bootstrap.text) as {
      history: { text: string | null }[];
    };
    expect(history.history.map((item) => item.text).filter(Boolean)).toEqual([
      "**Exact user text**",
      "Previous answer",
    ]);
    expect(bootstrap.text).not.toContain("Current request");
    expect(bootstrap.conversationId).toBe(conversation.id);
    expect(bootstrap.contextRevision).toBe(1);
    expect(bootstrap.turnRevision).toBe(2);
    const document = JSON.parse(bootstrap.text);
    expect(document.kind).toBe("BootstrapContext");
    expect(document.context.workflowState.value).toMatchObject({
      workflowId: "chat",
      workflowVersion: 1,
      workRequestId: "R2",
      status: "running",
    });
    expect(document.context.importantDecisions).toEqual({});
    const stateless = await loadConversationBootstrap(
      f.db as unknown as D1Database,
      conversation.id,
      "R2",
      1,
      "stateless",
    );
    expect(JSON.parse(stateless.text).kind).toBe("StatelessContext");
    expect(JSON.parse(stateless.text).context.workflowState).toEqual(
      document.context.workflowState,
    );

    await expect(
      loadConversationBootstrap(
        f.db as unknown as D1Database,
        "foreign",
        "R2",
        0,
      ),
    ).rejects.toThrow(/boundary/);
    await expect(
      loadConversationBootstrap(
        f.db as unknown as D1Database,
        conversation.id,
        "missing",
        0,
      ),
    ).rejects.toThrow(/boundary/);
    f.sqlite
      .prepare(
        `INSERT INTO conversation_history_entries
      (conversation_id, sequence, kind, event_type, actor_type, source_id, text, metadata_json, occurred_at)
      SELECT ?1, MAX(sequence)+1, 'user_message', 'user_message', 'user', 'huge-source', ?2, '{}', 'now'
      FROM conversation_history_entries WHERE conversation_id = ?1`,
      )
      .run(conversation.id, "x".repeat(256 * 1024 + 1));
    f.sqlite
      .exec(`INSERT INTO work_requests(id,workstream_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at)
      VALUES('R3','W','U','stateless','chat',1,'{}','running','{"originalRequest":"Next request"}','now','now')`);
    await f.db.batch(
      conversationSubmissionStatements(
        f.db as unknown as D1Database,
        "W",
        CONVERSATION_WORKFLOWS.chat!,
        "R3",
        "now",
      ),
    );
    await expect(
      loadConversationBootstrap(
        f.db as unknown as D1Database,
        conversation.id,
        "R3",
        2,
      ),
    ).rejects.toThrow(/limit/);
  } finally {
    f.sqlite.close();
  }
});

it("assembles Work environment and scoped prerequisite results for the receiving step", async () => {
  const f = await conversationFixture();
  try {
    const snapshot = JSON.stringify({
      projectInstructions: "Project rules",
      workstreamInstructions: "Stream rules",
      resolvedBindings: { direct: { workerId: "worker-chatgpt" } },
    });
    f.sqlite
      .prepare(
        `INSERT INTO work_requests(id,workstream_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,snapshot_json,primary_workspace_id,status,input_json,created_at,updated_at)
      VALUES('RW','W','U','stateful','direct',2,'{}',?,'WS','running','{}','now','now')`,
      )
      .run(snapshot);
    await f.db.batch(
      conversationSubmissionStatements(
        f.db as unknown as D1Database,
        "W",
        CONVERSATION_WORKFLOWS.work!,
        "RW",
        "now",
      ),
    );
    f.sqlite
      .exec(`INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,attempt,output_json,created_at,updated_at) VALUES
      ('IMPLEMENT','RW','implement','stateful_workstream',1000,'implement:v1','completed',1,'{"text":"Implementation result","workerId":"ChatGPT"}','now','now'),
      ('VERIFY','RW','verify','stateless_read',1000,'verify:v1','queued',0,NULL,'now','now'),
      ('TEST','RW','test','stateless_read',1000,'test:v1','completed',1,'{"text":"Unrelated test output"}','now','now');
      INSERT INTO workflow_task_dependencies(task_id,depends_on_task_id) VALUES('VERIFY','IMPLEMENT');
      INSERT INTO artifacts(id,project_id,workstream_id,work_request_id,content_digest,storage_key,created_at) VALUES('AR','P','W','RW','digest','secret-storage-key','now');`);
    const row = f.sqlite
      .prepare("SELECT id FROM conversations WHERE workflow_id='work'")
      .get() as { id: string };
    const result = await loadConversationBootstrap(
      f.db as unknown as D1Database,
      row.id,
      "RW",
      0,
      "bootstrap",
      "VERIFY",
    );
    const context = JSON.parse(result.text);
    expect(context.workflowExecutionContext).toMatchObject({
      activeStepId: "VERIFY",
      environment: {
        projectId: "P",
        workstreamId: "W",
        workspaceId: "WS",
        projectInstructions: "Project rules",
      },
      artifacts: [{ id: "AR", contentDigest: "digest" }],
      prerequisiteResults: [
        {
          stepId: "IMPLEMENT",
          workerId: "ChatGPT",
          text: "Implementation result",
        },
      ],
    });
    expect(context.conversationContext).not.toHaveProperty("workflowState");
    expect(result.text).not.toContain("Unrelated test output");
    expect(result.text).not.toContain("secret-storage-key");
    await expect(
      loadConversationBootstrap(
        f.db as unknown as D1Database,
        row.id,
        "RW",
        0,
        "bootstrap",
        "T",
      ),
    ).rejects.toThrow(/outside/);
    const chatRow = f.sqlite
      .prepare("SELECT id FROM conversations WHERE workflow_id='chat'")
      .get() as { id: string };
    const chat = JSON.parse(
      (
        await loadConversationBootstrap(
          f.db as unknown as D1Database,
          chatRow.id,
          "R",
          0,
          "bootstrap",
          "T",
        )
      ).text,
    );
    expect(chat.workflowExecutionContext.environment).toBeNull();
    expect(chat.workflowExecutionContext.artifacts).toEqual([]);
  } finally {
    f.sqlite.close();
  }
});
