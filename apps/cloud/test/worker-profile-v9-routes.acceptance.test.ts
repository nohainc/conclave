import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { DESKTOP_PROFILE_LAB_AUDIENCE } from "@conclave/security";
import { routeHandlers } from "../src/index.js";
import { generateEd25519ReleaseKeyPair } from "../src/release-trust.js";
import {
  validateWorkerProfileCandidate,
  type WorkerProfilePublicationEvidence,
} from "../src/tool-profile-registry.js";
import { toolProfileAcceptanceScenarioStatuses } from "../src/tool-profile-validation.js";
import {
  json,
  errorMessage,
  HttpError,
  requireSameOriginForCookieMutation,
} from "../src/routes/handlers.js";
import {
  routeWorkerRequest,
  type WorkerRouteDependencies,
  type WorkerRouteHandlers,
} from "../src/routes/router.js";
import { sqliteD1 } from "./helpers/sqlite-d1.js";

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

const routeDependencies: WorkerRouteDependencies = {
  json,
  requireSameOriginForCookieMutation,
  errorMessage,
  HttpError: HttpError as unknown as WorkerRouteDependencies["HttpError"],
};

function setup() {
  const { db, sqlite } = sqliteD1();
  sqlite.exec(
    readFileSync(
      new URL("../migrations-v8/0043_worker_profiles_v9.sql", import.meta.url),
      "utf8",
    ),
  );
  const now = new Date().toISOString();
  sqlite
    .prepare(
      `INSERT INTO users (id, email, display_name, status, created_at, updated_at)
       VALUES (?, ?, ?, 'active', ?, ?)`,
    )
    .run("profile-lab", "profile-lab@routes.test", "Profile Lab", now, now);
  sqlite
    .prepare(
      `INSERT INTO worker_catalog
         (worker_type_id, display_name, description, lifecycle_state,
          created_at, updated_at, engine_family, visibility_state,
          release_stage, sort_order)
       VALUES (?, ?, ?, 'active', ?, ?, 'cli', 'visible', 'stable', ?)`,
    )
    .run("route-worker", "Route Worker", "V9 route fixture", now, now, 1);

  const keyPair = generateEd25519ReleaseKeyPair();
  const env = {
    CONCLAVE_ENVIRONMENT: "development",
    CONCLAVE_DB: db,
    CONCLAVE_PROFILE_ADMIN_USER_IDS: "profile-lab",
    CONCLAVE_PROFILE_RELEASE_MANAGER_USER_IDS: "profile-lab",
    CONCLAVE_RELEASE_PUBLISHER: "conclave",
    CONCLAVE_RELEASE_SIGNING_KEY_ID: "route-key",
    CONCLAVE_RELEASE_PRIVATE_KEY: keyPair.privateKeyBase64,
    CONCLAVE_RELEASE_TRUST_KEYS_JSON: JSON.stringify({
      conclave: { "route-key": keyPair.publicKeyBase64 },
    }),
    TEST_AUTHENTICATION: async () => ({
      userId: "profile-lab",
      user: {
        id: "profile-lab",
        email: "profile-lab@routes.test",
        displayName: "Profile Lab",
        status: "active",
      },
      spaceRoles: {},
      sessionId: "profile-lab-session",
      clientType: "desktop",
      audience: DESKTOP_PROFILE_LAB_AUDIENCE,
    }),
  } as unknown as Env;
  return { db, sqlite, env };
}

function candidate() {
  const profile = structuredClone(fixture) as Record<string, unknown>;
  profile.logicalWorkerTypeId = "route-worker";
  return profile;
}

async function send(
  env: Env,
  method: string,
  path: string,
  body?: unknown,
): Promise<{ response: Response; body: Record<string, unknown> }> {
  const response = await routeWorkerRequest(
    new Request(`https://conclave.test${path}`, {
      method,
      headers: body === undefined ? {} : { "content-type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    }),
    env,
    undefined,
    routeHandlers as unknown as WorkerRouteHandlers,
    routeDependencies,
  );
  return { response, body: (await response.json()) as Record<string, unknown> };
}

describe("V9 Worker Profile routes", () => {
  it("supports validate, publish, read, history, and revision conflict operations", async () => {
    const { env, sqlite } = setup();
    try {
      const profile = candidate();
      const validated = await validateWorkerProfileCandidate(
        "route-worker",
        profile,
      );
      const evidence: WorkerProfilePublicationEvidence = {
        formatVersion: 1,
        workerTypeId: "route-worker",
        candidateDigest: validated.digest,
        engineVersion: "1.2.0",
        providerToolName: String(
          (profile.providerTool as Record<string, unknown>).name,
        ),
        providerToolVersion: "0.3.1",
        testedAt: new Date().toISOString(),
        scenarios: toolProfileAcceptanceScenarioStatuses(validated.profile),
      };

      const listed = await send(env, "GET", "/api/admin/workers");
      expect(listed.response.status).toBe(200);
      expect(listed.body.workers).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ workerTypeId: "route-worker" }),
        ]),
      );

      const checked = await send(
        env,
        "POST",
        "/api/admin/workers/route-worker/profile/validate",
        { profile, candidateDigest: validated.digest, evidence },
      );
      expect(checked.response.status).toBe(200);
      expect(checked.body).toEqual(
        expect.objectContaining({ valid: true, digest: validated.digest }),
      );

      const published = await send(
        env,
        "PUT",
        "/api/admin/workers/route-worker/profile",
        {
          expectedRevision: 0,
          profile,
          candidateDigest: validated.digest,
          evidence,
        },
      );
      expect(published.response.status).toBe(200);
      expect(published.body).toEqual(
        expect.objectContaining({ revision: 1, verified: true }),
      );

      const current = await send(
        env,
        "GET",
        "/api/admin/workers/route-worker/profile",
      );
      expect(current.response.status).toBe(200);
      expect(current.body.revision).toBe(1);

      const history = await send(
        env,
        "GET",
        "/api/admin/workers/route-worker/profile/history",
      );
      expect(history.response.status).toBe(200);
      expect(history.body.history).toEqual([]);

      const stale = await send(
        env,
        "PUT",
        "/api/admin/workers/route-worker/profile",
        {
          expectedRevision: 0,
          profile,
          candidateDigest: validated.digest,
          evidence,
        },
      );
      expect(stale.response.status).toBe(409);
    } finally {
      sqlite.close();
    }
  });
});
