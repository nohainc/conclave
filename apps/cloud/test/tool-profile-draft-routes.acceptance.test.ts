import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { DESKTOP_PROFILE_LAB_AUDIENCE } from "@conclave/security";
import { routeHandlers } from "../src/index.js";
import { generateEd25519ReleaseKeyPair } from "../src/release-trust.js";
import {
  errorMessage,
  HttpError,
  json,
  requireSameOriginForCookieMutation,
} from "../src/routes/handlers.js";
import {
  routeWorkerRequest,
  type WorkerRouteDependencies,
  type WorkerRouteHandlers,
} from "../src/routes/router.js";

type SqlValue = null | string | number | bigint | Uint8Array;
type SqliteStatement = {
  all(...values: SqlValue[]): Record<string, unknown>[];
  get(...values: SqlValue[]): Record<string, unknown> | undefined;
  run(...values: SqlValue[]): {
    changes: number | bigint;
    lastInsertRowid: number | bigint;
  };
};
type SqliteDatabase = {
  exec(sql: string): void;
  prepare(sql: string): SqliteStatement;
  close(): void;
};

const require = createRequire(import.meta.url);
const { DatabaseSync } = require("node:sqlite") as {
  DatabaseSync: new (path: string) => SqliteDatabase;
};
const migration = readFileSync(
  fileURLToPath(
    new URL("../migrations-v8/0001_conclave_v8.sql", import.meta.url),
  ),
  "utf8",
);
const fixture = JSON.parse(
  readFileSync(
    fileURLToPath(
      new URL(
        "../../../packages/tool-profile/test/fixtures/fixture-cli.v1.json",
        import.meta.url,
      ),
    ),
    "utf8",
  ),
) as Record<string, unknown>;

class SqliteD1 {
  readonly sqlite: SqliteDatabase;
  private readonly executeStatement = new WeakMap<
    object,
    () => Promise<unknown>
  >();

  constructor() {
    this.sqlite = new DatabaseSync(":memory:");
    this.sqlite.exec(migration);
    this.sqlite
      .prepare(
        `INSERT INTO users (id, email, display_name, status, created_at, updated_at)
         VALUES (?, ?, ?, 'active', ?, ?)`,
      )
      .run(
        "profile-lab-operator",
        "profile-lab@example.test",
        "Profile Lab Operator",
        new Date().toISOString(),
        new Date().toISOString(),
      );
  }

  prepare(sql: string): D1PreparedStatement {
    const sqlite = this.sqlite;
    let values: SqlValue[] = [];
    const statement = {
      bind(...next: unknown[]) {
        values = next.map((value) =>
          value === undefined ? null : value,
        ) as SqlValue[];
        return statement;
      },
      async first<T>(columnName?: string): Promise<T | null> {
        const row = sqlite.prepare(sql).get(...values);
        if (!row) return null;
        return (columnName ? row[columnName] : row) as T;
      },
      async all<T>(): Promise<D1Result<T>> {
        const rows = sqlite.prepare(sql).all(...values) as T[];
        return {
          results: rows,
          success: true,
          meta: { changes: rows.length },
        } as D1Result<T>;
      },
      async run<T>(): Promise<D1Result<T>> {
        const result = sqlite.prepare(sql).run(...values);
        return {
          success: true,
          meta: {
            changes: Number(result.changes),
            last_row_id: Number(result.lastInsertRowid),
          },
        } as D1Result<T>;
      },
    };
    this.executeStatement.set(statement, () => statement.run());
    return statement as unknown as D1PreparedStatement;
  }

  async batch<T = unknown>(
    statements: D1PreparedStatement[],
  ): Promise<D1Result<T>[]> {
    this.sqlite.exec("BEGIN");
    try {
      const results = await Promise.all(
        statements.map((statement) => {
          const execute = this.executeStatement.get(statement);
          if (!execute) throw new Error("Unknown D1 statement in batch");
          return execute();
        }),
      );
      this.sqlite.exec("COMMIT");
      return results as D1Result<T>[];
    } catch (error) {
      this.sqlite.exec("ROLLBACK");
      throw error;
    }
  }

  close(): void {
    this.sqlite.close();
  }
}

const routeDependencies: WorkerRouteDependencies = {
  json,
  requireSameOriginForCookieMutation,
  errorMessage,
  HttpError: HttpError as unknown as WorkerRouteDependencies["HttpError"],
};

function makeProfile(
  profileDefinitionId: string,
  workerTypeId: string,
  releaseVersion: number,
): Record<string, unknown> {
  const profile = structuredClone(fixture);
  profile.profileDefinitionId = profileDefinitionId;
  profile.logicalWorkerTypeId = workerTypeId;
  profile.releaseVersion = releaseVersion;
  (profile.providerTool as Record<string, unknown>).executableCandidates = [
    "route-fixture-cli",
  ];
  return profile;
}

function makeEnv(db: SqliteD1): Env {
  const keyPair = generateEd25519ReleaseKeyPair();
  return {
    CONCLAVE_ENVIRONMENT: "development",
    CONCLAVE_DB: db as unknown as D1Database,
    CONCLAVE_PROFILE_ADMIN_USER_IDS: "profile-lab-operator",
    CONCLAVE_PROFILE_RELEASE_MANAGER_USER_IDS: "profile-lab-operator",
    CONCLAVE_RELEASE_PUBLISHER: "conclave",
    CONCLAVE_RELEASE_SIGNING_KEY_ID: "acceptance-key",
    CONCLAVE_RELEASE_PRIVATE_KEY: keyPair.privateKeyBase64,
    CONCLAVE_RELEASE_TRUST_KEYS_JSON: JSON.stringify({
      conclave: { "acceptance-key": keyPair.publicKeyBase64 },
    }),
    TEST_AUTHENTICATION: async () => ({
      userId: "profile-lab-operator",
      user: {
        id: "profile-lab-operator",
        email: "profile-lab@example.test",
        displayName: "Profile Lab Operator",
        status: "active",
      },
      projectRoles: {},
      sessionId: "profile-lab-session",
      clientType: "desktop",
      audience: DESKTOP_PROFILE_LAB_AUDIENCE,
    }),
  } as unknown as Env;
}

async function send(
  env: Env,
  method: string,
  path: string,
  body?: unknown,
  headers: Record<string, string> = {},
): Promise<{ response: Response; json: Record<string, unknown> }> {
  const response = await routeWorkerRequest(
    new Request(`https://conclave.test${path}`, {
      method,
      headers: {
        ...(body === undefined ? {} : { "content-type": "application/json" }),
        ...headers,
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    }),
    env,
    undefined,
    routeHandlers as unknown as WorkerRouteHandlers,
    routeDependencies,
  );
  const json = (await response.json()) as Record<string, unknown>;
  return { response, json };
}

async function assertOk(
  env: Env,
  method: string,
  path: string,
  body?: unknown,
  headers: Record<string, string> = {},
): Promise<Record<string, unknown>> {
  const { response, json } = await send(env, method, path, body, headers);
  expect(
    response.status,
    `${method} ${path}: ${JSON.stringify(json)}`,
  ).toBeLessThan(300);
  expect(
    response.status,
    `${method} ${path}: ${JSON.stringify(json)}`,
  ).toBeGreaterThanOrEqual(200);
  return json;
}

async function createWorker(
  env: Env,
  workerTypeId: string,
  profileDefinitionId: string,
): Promise<void> {
  const { response, json } = await send(
    env,
    "POST",
    "/api/admin/workers/catalog",
    {
      workerTypeId,
      profileDefinitionId,
      displayName: "Route Fixture Worker",
      description: "Cloud route acceptance Worker",
      providerToolName: "route-fixture-cli",
      releaseStage: "testing",
      capabilities: ["text"],
      sortOrder: 9000,
    },
  );
  expect(response.status, JSON.stringify(json)).toBe(201);
}

async function createSaveQualifyAndPublishV1(
  env: Env,
  profileDefinitionId: string,
  workerTypeId: string,
): Promise<void> {
  const path = `/api/admin/tool-profiles/${profileDefinitionId}/releases`;
  const initialProfile = makeProfile(profileDefinitionId, workerTypeId, 1);
  const created = await assertOk(env, "POST", path, {
    releaseVersion: 1,
    profile: initialProfile,
  });
  expect(created.status).toBe("draft");

  const changedProfile = {
    ...initialProfile,
    timeout: { providerArguments: [], providerReserveMs: 25 },
  };
  const saved = await assertOk(
    env,
    "PUT",
    `${path}/1/draft`,
    { profile: changedProfile },
    { "If-Match": `"${String(created.payloadDigest)}"` },
  );

  const evidence = {
    formatVersion: 2,
    profileDefinitionId,
    releaseVersion: 1,
    profileReleaseVersion: "1",
    logicalWorkerTypeId: workerTypeId,
    profileDigest: saved.payloadDigest,
    engineVersion: "1.0.0",
    providerToolName: "Fixture CLI",
    providerToolVersion: "0.3.1",
    acceptedAt: new Date().toISOString(),
    scenarios: {
      passive_probe: "passed",
      live_probe: "passed",
      model_selection: "not_applicable",
      representative_workstream_write: "not_applicable",
      durable_session_start: "not_applicable",
      durable_session_resume: "not_applicable",
      cancellation: "passed",
      timeout: "passed",
    },
  };
  const qualified = await assertOk(env, "POST", `${path}/1/qualification`, {
    evidence,
  });
  expect(qualified.qualificationEvidenceId).toEqual(expect.any(String));

  const published = await assertOk(env, "POST", `${path}/1/publish`, {
    qualificationEvidenceId: qualified.qualificationEvidenceId,
  });
  expect(published.status).toBe("testing");
}

describe("Tool Profile Cloud draft route acceptance", () => {
  it("grants only the configured owner development access without email verification and keeps signing disabled", async () => {
    const db = new SqliteD1();
    const env = Object.assign(makeEnv(db), {
      CONCLAVE_PROFILE_LAB_OWNER_EMAIL: "vitalii@nohainc.com",
      CONCLAVE_PROFILE_RELEASE_MODE: "drafts-only",
    });
    try {
      // Existing ID allowlists must not override the exclusive owner policy.
      const denied = await send(env, "GET", "/api/admin/workers/catalog");
      expect(denied.response.status).toBe(403);
      db.sqlite
        .prepare("UPDATE users SET email = ?, email_verified = 0 WHERE id = ?")
        .run("vitalii@nohainc.com", "profile-lab-operator");
      const access = await assertOk(
        env,
        "GET",
        "/api/admin/profile-lab/access",
      );
      expect(access.schemaVersion).toBe(1);
      expect(access.permissions).toEqual({
        profilesAdmin: true,
        releaseManager: true,
      });
      expect(access.releaseMode).toBe("drafts-only");
      expect(access.signer).toEqual({
        ready: false,
        issues: ["publication_disabled_for_development"],
      });
      await assertOk(env, "GET", "/api/admin/workers/catalog");
      const preflight = await assertOk(
        env,
        "GET",
        "/api/admin/tool-profiles/signing-preflight",
      );
      expect(preflight.ready).toBe(false);
      const publish = await send(
        env,
        "POST",
        "/api/admin/tool-profiles/chatgpt-codex/releases/1/publish",
        { qualificationEvidenceId: "not-used" },
      );
      expect(publish.response.status).toBe(409);
      expect(JSON.stringify(publish.json)).toContain(
        "disabled during development",
      );
      expect(
        db.sqlite
          .prepare("SELECT COUNT(*) AS count FROM tool_profile_releases")
          .get()?.count,
      ).toBe(0);
    } finally {
      db.close();
    }
  });

  it("returns the fresh v8 bootstrap Workers through the administrative catalog", async () => {
    const db = new SqliteD1();
    try {
      const rows = db.sqlite
        .prepare(
          "SELECT worker_type_id FROM worker_catalog ORDER BY sort_order",
        )
        .all();
      expect(rows.map((row) => row.worker_type_id)).toEqual(
        expect.arrayContaining(["chatgpt", "gemini"]),
      );
      const catalog = await assertOk(
        makeEnv(db),
        "GET",
        "/api/admin/workers/catalog",
      );
      expect(
        (catalog.workers as { workerTypeId: string }[]).map(
          (worker) => worker.workerTypeId,
        ),
      ).toEqual(expect.arrayContaining(["chatgpt", "gemini"]));
      expect(
        db.sqlite
          .prepare("SELECT COUNT(*) AS count FROM tool_profile_releases")
          .get()?.count,
      ).toBe(0);
    } finally {
      db.close();
    }
  });
  it("creates a Worker, creates and saves draft v1, qualifies it, and publishes", async () => {
    const db = new SqliteD1();
    const env = makeEnv(db);
    try {
      await createWorker(env, "route-fixture-worker", "route-fixture-profile");
      await createSaveQualifyAndPublishV1(
        env,
        "route-fixture-profile",
        "route-fixture-worker",
      );
      const release = await assertOk(
        env,
        "GET",
        "/api/admin/tool-profiles/route-fixture-profile/releases/1",
      );
      expect(release.lifecycleState).toBe("testing");
      expect(release.signature).toEqual(expect.any(String));
    } finally {
      db.close();
    }
  });

  it("creates draft v2 through POST after v1 is Stable", async () => {
    const db = new SqliteD1();
    const env = makeEnv(db);
    try {
      const workerTypeId = "stable-route-fixture-worker";
      const profileDefinitionId = "stable-route-fixture-profile";
      await createWorker(env, workerTypeId, profileDefinitionId);
      await createSaveQualifyAndPublishV1(
        env,
        profileDefinitionId,
        workerTypeId,
      );
      const timestamp = new Date().toISOString();
      db.sqlite
        .prepare(
          `UPDATE tool_profile_releases SET lifecycle_state = 'stable', updated_at = ?
            WHERE profile_definition_id = ? AND release_version = 1`,
        )
        .run(timestamp, profileDefinitionId);
      db.sqlite
        .prepare(
          `INSERT INTO tool_profile_channel_pointers
             (profile_definition_id, channel, release_version, modified_by_user_id, updated_at)
           VALUES (?, 'stable', 1, 'profile-lab-operator', ?)`,
        )
        .run(profileDefinitionId, timestamp);

      const draftV2 = makeProfile(profileDefinitionId, workerTypeId, 2);
      const created = await assertOk(
        env,
        "POST",
        `/api/admin/tool-profiles/${profileDefinitionId}/releases`,
        { releaseVersion: 2, profile: draftV2 },
      );
      expect(created).toMatchObject({ status: "draft" });
      const releaseV1 = await assertOk(
        env,
        "GET",
        `/api/admin/tool-profiles/${profileDefinitionId}/releases/1`,
      );
      const releaseV2 = await assertOk(
        env,
        "GET",
        `/api/admin/tool-profiles/${profileDefinitionId}/releases/2`,
      );
      expect(releaseV1.lifecycleState).toBe("stable");
      expect(releaseV2.lifecycleState).toBe("draft");
      expect(releaseV2.profile).toMatchObject({ releaseVersion: 2 });
    } finally {
      db.close();
    }
  });

  it("applies If-Match concurrency and permits explicit force saves", async () => {
    const db = new SqliteD1();
    const env = makeEnv(db);
    const profileDefinitionId = "concurrency-route-profile";
    const workerTypeId = "concurrency-route-worker";
    try {
      await createWorker(env, workerTypeId, profileDefinitionId);
      const baseProfile = makeProfile(profileDefinitionId, workerTypeId, 1);
      const created = await assertOk(
        env,
        "POST",
        `/api/admin/tool-profiles/${profileDefinitionId}/releases`,
        { releaseVersion: 1, profile: baseProfile },
      );
      const draftPath = `/api/admin/tool-profiles/${profileDefinitionId}/releases/1/draft`;
      const matchingSave = await send(
        env,
        "PUT",
        draftPath,
        {
          profile: {
            ...baseProfile,
            timeout: { providerArguments: [], providerReserveMs: 10 },
          },
        },
        { "If-Match": `"${String(created.payloadDigest)}"` },
      );
      expect(matchingSave.response.status).toBe(200);

      const staleSave = await send(
        env,
        "PUT",
        draftPath,
        {
          profile: {
            ...baseProfile,
            timeout: { providerArguments: [], providerReserveMs: 20 },
          },
        },
        { "If-Match": `"${String(created.payloadDigest)}"` },
      );
      expect(staleSave.response.status).toBe(409);
      expect(staleSave.json.error).toContain("draft conflict");

      const forceSave = await send(env, "PUT", draftPath, {
        profile: {
          ...baseProfile,
          timeout: { providerArguments: [], providerReserveMs: 20 },
        },
      });
      expect(forceSave.response.status).toBe(200);
    } finally {
      db.close();
    }
  });
});
