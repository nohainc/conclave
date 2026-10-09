import { readFileSync } from "node:fs";
import { expect, it } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";

it("replaces the retired Space-wide denial with disabled Work workflows without losing choices or authored context", () => {
  const { sqlite } = sqliteD1();
  try {
    sqlite.exec(`DROP TABLE user_workflow_settings;
      DROP TABLE space_workflow_settings;
      INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('u','u@test','User','now','now');
      INSERT INTO spaces(id,owner_user_id,name,settings_json,created_at,updated_at) VALUES
        ('denied','u','Denied','{"allowWork":false,"instructions":"Keep context"}','now','now'),
        ('allowed','u','Allowed','{"allowWork":true}','now','now');
      INSERT INTO space_workflow_configurations VALUES('denied','direct',1,'{"schemaVersion":1,"workflowId":"direct","enabled":true,"defaults":{"worker":"saved"},"stepOverrides":{"implement":{"effort":"high"}}}','now');`);
    sqlite.exec(
      readFileSync(
        new URL(
          "../migrations-v8/0022_workflow_workspace_selection.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    const rows = sqlite
      .prepare(
        "SELECT workflow_id,configuration_json FROM space_workflow_configurations WHERE space_id='denied'",
      )
      .all();
    expect(rows).toHaveLength(5);
    expect(
      rows.every(
        (row) => JSON.parse(String(row.configuration_json)).enabled === false,
      ),
    ).toBe(true);
    expect(
      JSON.parse(
        String(
          rows.find((row) => row.workflow_id === "direct")!.configuration_json,
        ),
      ),
    ).toMatchObject({
      defaults: { worker: "saved" },
      stepOverrides: { implement: { effort: "high" } },
    });
    expect(
      JSON.parse(
        String(
          sqlite
            .prepare("SELECT settings_json FROM spaces WHERE id='denied'")
            .get()!.settings_json,
        ),
      ),
    ).toEqual({ instructions: "Keep context" });
    expect(
      sqlite
        .prepare(
          "SELECT COUNT(*) n FROM space_workflow_configurations WHERE space_id='allowed' OR workflow_id='chat'",
        )
        .get(),
    ).toEqual({ n: 0 });
    expect(
      sqlite.prepare("SELECT COUNT(*) n FROM user_workflow_settings").get(),
    ).toEqual({ n: 0 });
  } finally {
    sqlite.close();
  }
});
