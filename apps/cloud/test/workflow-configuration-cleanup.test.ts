import { expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
it("cleans obsolete Thread choices while preserving authored context and frozen history", () => {
  const { sqlite } = sqliteD1();
  try {
    sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('u','u@test','U','now','now');
 INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('s','u','S','now','now');
 INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('t','s','T','active','u','now','now');`);
    const config = {
      defaultWorkflowId: "direct",
      threadInstructions: "Authored context",
      bindings: {
        direct: {
          workerId: "offline",
          workerLabel: { displayName: "Worker", workspaceName: "Laptop" },
          model: "model",
          reasoningEffort: "high",
          fallbackWorkerId: "fallback",
          additionalInstructions: " Keep this ",
        },
        chat: { workerId: "other" },
        verify: { additionalInstructions: " " },
      },
    };
    sqlite
      .prepare(
        "INSERT INTO thread_work_configs(thread_id,config_json,updated_at) VALUES('t',?,'now')",
      )
      .run(JSON.stringify(config));
    const frozen = {
      schemaVersion: 1,
      resolvedBindings: {
        direct: {
          workerId: "offline",
          model: "model",
          reasoningEffort: "high",
        },
      },
    };
    sqlite
      .prepare(
        `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,snapshot_json,status,input_json,created_at,updated_at) VALUES('r','t','u','stateful','direct',2,'{}',?,'queued','{}','now','now')`,
      )
      .run(JSON.stringify(frozen));
    const migration = readFileSync(
      new URL(
        "../migrations-v8/0019_thread_execution_configuration_cleanup.sql",
        import.meta.url,
      ),
      "utf8",
    );
    sqlite.exec(migration);
    const read = () =>
      JSON.parse(
        String(
          sqlite.prepare("SELECT config_json FROM thread_work_configs").get()!
            .config_json,
        ),
      );
    expect(read()).toEqual({
      defaultWorkflowId: "direct",
      threadInstructions: "Authored context",
      bindings: { direct: { additionalInstructions: "Keep this" } },
    });
    expect(
      JSON.parse(
        String(
          sqlite.prepare("SELECT snapshot_json FROM work_requests").get()!
            .snapshot_json,
        ),
      ),
    ).toEqual(frozen);
    sqlite.exec(migration);
    expect(read().bindings).toEqual({
      direct: { additionalInstructions: "Keep this" },
    });
  } finally {
    sqlite.close();
  }
});
