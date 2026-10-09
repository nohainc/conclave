import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { readFileSync } from "node:fs";

class Statement {
  constructor(
    readonly db: DatabaseSync,
    readonly sql: string,
    readonly values: SQLInputValue[] = [],
  ) {}
  bind(...values: SQLInputValue[]) {
    return new Statement(this.db, this.sql, values);
  }
  async first<T>() {
    return (this.db.prepare(this.sql).get(...this.values) ?? null) as T | null;
  }
  async all<T>() {
    const statement = this.db.prepare(this.sql);
    if (statement.columns().length > 0)
      return {
        success: true,
        results: statement.all(...this.values) as T[],
        meta: { changes: 0 },
      };
    const result = statement.run(...this.values);
    return {
      success: true,
      results: [] as T[],
      meta: { changes: Number(result.changes) },
    };
  }
  run() {
    return this.all();
  }
}

export function sqliteD1() {
  const sqlite = new DatabaseSync(":memory:");
  sqlite.exec(
    readFileSync(
      new URL("../../migrations-v8/0001_conclave_v8.sql", import.meta.url),
      "utf8",
    ),
  );
  sqlite.exec("PRAGMA foreign_keys = ON");
  for (const migration of [
    "0006_chat_workflow_admission.sql",
    "0009_realtime_stream_alignment.sql",
    "0010_conversation_workflows.sql",
    "0011_conversation_turns.sql",
    "0012_canonical_conversation_history.sql",
    "0013_worker_session_context.sql",
    "0014_exact_history_context.sql",
    "0015_conversation_workflow_runs.sql",
    "0016_workflow_step_runs.sql",
    "0018_user_workflow_configurations.sql",
    "0020_space_workflow_configurations.sql",
    "0022_workflow_workspace_selection.sql",
    "0023_people_relationships.sql",
    "0024_space_invitation_identity.sql",
    "0025_remove_invite_members_permission.sql",
    "0026_remove_attach_workspace_permission.sql",
    "0027_enable_workflow_workspace_workers.sql",
    "0028_workflow_default_selection.sql",
  ]) {
    sqlite.exec(
      readFileSync(
        new URL(`../../migrations-v8/${migration}`, import.meta.url),
        "utf8",
      ),
    );
  }
  let pendingBatch: Promise<unknown> = Promise.resolve();
  const adapter = {
    prepare(sql: string) {
      return new Statement(sqlite, sql);
    },
    batch(statements: Statement[]) {
      const operation = pendingBatch.then(async () => {
        sqlite.exec("BEGIN");
        try {
          const results = [];
          for (const statement of statements)
            results.push(await statement.all());
          sqlite.exec("COMMIT");
          return results;
        } catch (error) {
          sqlite.exec("ROLLBACK");
          throw error;
        }
      });
      pendingBatch = operation.catch(() => {});
      return operation;
    },
  };
  return { sqlite, db: adapter as unknown as D1Database };
}
