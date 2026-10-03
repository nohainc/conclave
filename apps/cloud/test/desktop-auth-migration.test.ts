import { DatabaseSync } from "node:sqlite";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const migrationsDirectory = fileURLToPath(
  new URL("../migrations-v8/", import.meta.url),
);

function migrationSql(name: string): string {
  return readFileSync(join(migrationsDirectory, name), "utf8");
}

function orderedMigrationFiles(): string[] {
  return readdirSync(migrationsDirectory)
    .filter((file) => file.endsWith(".sql"))
    .sort();
}

function legacyProductionBaseline(): string {
  let sql = migrationSql("0001_conclave_v8.sql");
  const oldAuthIntentDefinition = sql.replace(
    / {2}audience TEXT NOT NULL DEFAULT 'conclave\.desktop\.management' CHECK \(audience IN \('conclave\.desktop\.management', 'conclave\.profile-lab\.management'\)\),\n/,
    "",
  );
  expect(oldAuthIntentDefinition).not.toBe(sql);
  sql = oldAuthIntentDefinition.replace(
    /audience TEXT NOT NULL CHECK \(audience IN \('conclave\.desktop\.management', 'conclave\.profile-lab\.management'\)\)/,
    "audience TEXT NOT NULL CHECK (audience = 'conclave.desktop.management')",
  );
  expect(sql).not.toBe(oldAuthIntentDefinition);
  return sql;
}

function createDatabase(): DatabaseSync {
  const database = new DatabaseSync(":memory:");
  database.exec("PRAGMA foreign_keys = ON");
  return database;
}

describe("desktop auth multi-audience migration", () => {
  it("preserves existing intents and active human sessions from the deployed baseline", () => {
    const database = createDatabase();
    database.exec(legacyProductionBaseline());
    database.exec(`
      INSERT INTO users
        (id, email, display_name, created_at, updated_at)
      VALUES ('owner', 'owner@example.invalid', 'Owner', 'now', 'now');

      INSERT INTO desktop_auth_intents
        (id, poll_token_hash, client_name, created_at, expires_at,
         approved_at, approved_user_id, claimed_at, claimed_session_id, denied_at)
      VALUES
        ('pending-intent', 'poll-hash-pending', 'Workspace', 'created', 'expires',
         NULL, NULL, NULL, NULL, NULL),
        ('claimed-intent', 'poll-hash-claimed', 'Workspace', 'created-2', 'expires-2',
         'approved', 'owner', 'claimed', 'active-session', NULL);

      INSERT INTO desktop_human_sessions
        (id, user_id, token_hash, audience, created_at, last_used_at,
         expires_at, revoked_at)
      VALUES
        ('active-session', 'owner', 'active-hash', 'conclave.desktop.management',
         'created', 'last-used', 'expires', NULL),
        ('revoked-session', 'owner', 'revoked-hash', 'conclave.desktop.management',
         'created-2', 'last-used-2', 'expires-2', 'revoked');
    `);

    const intentsBefore = database
      .prepare("SELECT * FROM desktop_auth_intents ORDER BY id")
      .all();
    const sessionsBefore = database
      .prepare("SELECT * FROM desktop_human_sessions ORDER BY id")
      .all();

    database.exec(migrationSql("0002_desktop_auth_multi_audience.sql"));

    const intentsAfter = database
      .prepare("SELECT * FROM desktop_auth_intents ORDER BY id")
      .all();
    expect(intentsAfter).toHaveLength(intentsBefore.length);
    expect(intentsAfter).toEqual(
      intentsBefore.map((row) => ({
        ...(row as Record<string, unknown>),
        audience: "conclave.desktop.management",
      })),
    );

    const sessionsAfter = database
      .prepare("SELECT * FROM desktop_human_sessions ORDER BY id")
      .all();
    expect(sessionsAfter).toEqual(sessionsBefore);
    expect(sessionsAfter).toContainEqual(
      expect.objectContaining({ id: "active-session", revoked_at: null }),
    );

    expect(
      database
        .prepare(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE '__migration_0002_%'",
        )
        .all(),
    ).toEqual([]);
    expect(
      database
        .prepare(
          "SELECT name FROM sqlite_master WHERE type = 'index' AND name IN (?, ?)",
        )
        .all(
          "idx_desktop_auth_intents_expiry",
          "idx_desktop_human_sessions_user",
        ),
    ).toHaveLength(2);

    database
      .prepare(
        `
      INSERT INTO desktop_auth_intents
        (id, poll_token_hash, client_name, audience, created_at, expires_at)
      VALUES ('lab-intent', 'lab-poll-hash', 'Profile Lab',
        'conclave.profile-lab.management', 'created', 'expires')
    `,
      )
      .run();
    database
      .prepare(
        `
      INSERT INTO desktop_human_sessions
        (id, user_id, token_hash, audience, created_at, last_used_at, expires_at)
      VALUES ('lab-session', 'owner', 'lab-session-hash',
        'conclave.profile-lab.management', 'created', 'last-used', 'expires')
    `,
      )
      .run();
    expect(() =>
      database
        .prepare(
          `
        INSERT INTO desktop_auth_intents
          (id, poll_token_hash, client_name, audience, created_at, expires_at)
        VALUES ('invalid-intent', 'invalid-poll-hash', 'Unknown', 'unknown',
          'created', 'expires')
      `,
        )
        .run(),
    ).toThrow();
    expect(() =>
      database
        .prepare(
          `
        INSERT INTO desktop_human_sessions
          (id, user_id, token_hash, audience, created_at, last_used_at, expires_at)
        VALUES ('invalid-session', 'owner', 'invalid-hash', 'unknown',
          'created', 'last-used', 'expires')
      `,
        )
        .run(),
    ).toThrow();

    database.close();
  });

  it("applies after the current clean baseline", () => {
    const database = createDatabase();
    for (const file of orderedMigrationFiles()) {
      database.exec(migrationSql(file));
    }

    const intentAudience = database
      .prepare("PRAGMA table_info(desktop_auth_intents)")
      .all()
      .map((column) => (column as { name: string }).name);
    expect(intentAudience).toContain("audience");
    expect(
      database
        .prepare(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE '__migration_0002_%'",
        )
        .all(),
    ).toEqual([]);

    database.close();
  });
});

describe("Workspace installation ownership migration", () => {
  it("preserves active ownership across rotated runtime identities and restores released ownership from audit history", () => {
    const database = createDatabase();
    database.exec(migrationSql("0001_conclave_v8.sql"));
    database.exec(migrationSql("0002_desktop_auth_multi_audience.sql"));
    database.exec(`
      INSERT INTO users
        (id, email, display_name, created_at, updated_at)
      VALUES ('owner', 'owner@example.invalid', 'Owner', 'now', 'now');
      INSERT INTO execution_workspaces
        (id, owner_user_id, name, status, created_at, updated_at)
      VALUES
        ('active-workspace', 'owner', 'Active', 'offline', 'created', 'updated'),
        ('released-workspace', 'owner', 'Released', 'revoked', 'created', 'updated');
      INSERT INTO workspace_runtime_identities
        (id, workspace_id, credential_token_hash, installation_id, created_at, revoked_at)
      VALUES
        ('runtime-old', 'active-workspace', 'hash-old', 'install_11111111-1111-4111-8111-111111111111', 'old', 'rotated'),
        ('runtime-current', 'active-workspace', 'hash-current', 'install_11111111-1111-4111-8111-111111111111', 'current', NULL),
        ('runtime-released', 'released-workspace', 'hash-released', NULL, 'released', 'released');
      INSERT INTO workspace_audit_log
        (id, workspace_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
      VALUES
        ('audit-release', 'released-workspace', 'user', 'owner',
         'workspace.ownership.released', 'workspace_runtime', 'runtime-released',
         '{"installationId":"install_22222222-2222-4222-8222-222222222222"}', 'released-at');
    `);
    const runtimeRowsBefore = database
      .prepare("SELECT * FROM workspace_runtime_identities ORDER BY id")
      .all();

    database.exec(migrationSql("0003_workspace_installations.sql"));

    expect(
      database
        .prepare(
          "SELECT installation_id, owner_user_id, workspace_id, status, released_at FROM workspace_installations ORDER BY installation_id",
        )
        .all(),
    ).toEqual([
      {
        installation_id: "install_11111111-1111-4111-8111-111111111111",
        owner_user_id: "owner",
        workspace_id: "active-workspace",
        status: "active",
        released_at: null,
      },
      {
        installation_id: "install_22222222-2222-4222-8222-222222222222",
        owner_user_id: "owner",
        workspace_id: "released-workspace",
        status: "released",
        released_at: "released-at",
      },
    ]);
    expect(
      database
        .prepare("SELECT * FROM workspace_runtime_identities ORDER BY id")
        .all(),
    ).toEqual(runtimeRowsBefore);
    expect(
      database
        .prepare(
          "SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?",
        )
        .get("idx_workspace_installations_active_workspace"),
    ).toBeTruthy();
    database.close();
  });

  it("fails closed when one legacy installation points to multiple Workspaces", () => {
    const database = createDatabase();
    database.exec(migrationSql("0001_conclave_v8.sql"));
    database.exec(migrationSql("0002_desktop_auth_multi_audience.sql"));
    database.exec(`
      INSERT INTO users
        (id, email, display_name, created_at, updated_at)
      VALUES ('owner', 'owner@example.invalid', 'Owner', 'now', 'now');
      INSERT INTO execution_workspaces
        (id, owner_user_id, name, status, created_at, updated_at)
      VALUES
        ('workspace-a', 'owner', 'A', 'offline', 'now', 'now'),
        ('workspace-b', 'owner', 'B', 'offline', 'now', 'now');
      INSERT INTO workspace_runtime_identities
        (id, workspace_id, credential_token_hash, installation_id, created_at, revoked_at)
      VALUES
        ('runtime-a', 'workspace-a', 'hash-a', 'install_33333333-3333-4333-8333-333333333333', 'now', NULL),
        ('runtime-b', 'workspace-b', 'hash-b', 'install_33333333-3333-4333-8333-333333333333', 'now', 'revoked');
    `);

    expect(() =>
      database.exec(migrationSql("0003_workspace_installations.sql")),
    ).toThrow();
    database.close();
  });
});
