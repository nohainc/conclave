import { describe, expect, it, beforeEach } from "vitest";
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import worker from "../src/index.js";
import { computePackageDigest } from "../../../packages/security/src/index.js";
import type { WorkerPluginManifest } from "../../../packages/plugin-sdk/src/manifest.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const schemaPath = path.resolve(__dirname, "../migrations/0001_initial.sql");

function createD1Mock(db: DatabaseSync) {
  return {
    prepare(query: string) {
      let params: Array<string | number | bigint | null | Uint8Array> = [];
      const stmtObj = {
        bind(...args: unknown[]) {
          params = args as Array<string | number | bigint | null | Uint8Array>;
          return stmtObj;
        },
        async first<T = Record<string, unknown>>() {
          const stmt = db.prepare(query);
          const res = stmt.get(...params) as T | undefined;
          return res ?? null;
        },
        async all<T = Record<string, unknown>>() {
          const stmt = db.prepare(query);
          const res = stmt.all(...params) as T[];
          return { results: res };
        },
        async run() {
          const stmt = db.prepare(query);
          stmt.run(...params);
          return { success: true };
        },
      };
      return stmtObj;
    },
    async batch(statements: Array<{ run: () => Promise<unknown> }>) {
      for (const stmt of statements) {
        await stmt.run();
      }
    },
  };
}

function createR2Mock() {
  const storage = new Map<
    string,
    {
      body: Uint8Array;
      httpMetadata?: Record<string, string>;
      customMetadata?: Record<string, string>;
    }
  >();

  return {
    async get(key: string) {
      const item = storage.get(key);
      if (!item) return null;
      return {
        key,
        body: new ReadableStream({
          start(controller) {
            controller.enqueue(item.body);
            controller.close();
          },
        }),
        async arrayBuffer() {
          return item.body.buffer;
        },
        async text() {
          return new TextDecoder().decode(item.body);
        },
        httpMetadata: item.httpMetadata,
        customMetadata: item.customMetadata,
        etag: `"${key}"`,
      };
    },
    async put(
      key: string,
      value: Uint8Array | string,
      options?: {
        httpMetadata?: Record<string, string>;
        customMetadata?: Record<string, string>;
      },
    ) {
      const body =
        typeof value === "string" ? new TextEncoder().encode(value) : value;
      storage.set(key, {
        body,
        httpMetadata: options?.httpMetadata,
        customMetadata: options?.customMetadata,
      });
      return {
        key,
        etag: `"${key}"`,
      };
    },
    async delete(key: string) {
      storage.delete(key);
    },
  };
}

interface TestEnv extends Env {
  CONCLAVE_ENVIRONMENT: "development";
  CONCLAVE_ALLOW_ANONYMOUS_DEV: "true";
  CONCLAVE_DB: D1Database;
  CONCLAVE_ARTIFACTS: R2Bucket;
  CONCLAVE_PLUGINS: R2Bucket;
}

describe("Architecture v2 Cloud Plugin Registry", () => {
  let db: DatabaseSync;
  let r2: ReturnType<typeof createR2Mock>;
  let env: TestEnv;

  beforeEach(() => {
    db = new DatabaseSync(":memory:");
    db.exec("PRAGMA foreign_keys = ON;");
    const sql = fs.readFileSync(schemaPath, "utf8");
    db.exec(sql);

    r2 = createR2Mock();

    env = {
      CONCLAVE_ENVIRONMENT: "development",
      CONCLAVE_ALLOW_ANONYMOUS_DEV: "true",
      CONCLAVE_PLUGIN_SIGNING_KEY: "test-plugin-signing-key",
      CONCLAVE_DB: createD1Mock(db) as unknown as D1Database,
      CONCLAVE_ARTIFACTS: r2 as unknown as R2Bucket,
      CONCLAVE_PLUGINS: r2 as unknown as R2Bucket,
    } as unknown as TestEnv;
  });

  const sampleManifest: WorkerPluginManifest = {
    pluginId: "conclave.codex",
    version: "1.0.0",
    displayName: "OpenAI Codex Worker Plugin",
    description: "Official Codex CLI worker plugin",
    publisher: "conclave-official",
    protocolVersion: "2.0",
    minimumAgentVersion: "0.2.0",
    supportedOS: ["macos", "linux"],
    supportedArchitecture: ["arm64", "x64"],
    roles: ["coder", "architect"],
    capabilities: ["code_write", "git_ops"],
    permissions: ["fs:read", "fs:write"],
    configurationSchema: {
      type: "object",
      properties: { model: { type: "string" } },
    },
    secretSchema: {
      OPENAI_API_KEY: { type: "string", required: true },
    },
    entrypoint: "dist/index.js",
    billingModes: ["api_metered", "subscription"],
    digest: "",
    channel: "stable",
  };

  it("publishes a plugin package to R2 and registers metadata in D1", async () => {
    const packagePayload = "export default function() { return 'ok'; }";
    const packageBytes = new TextEncoder().encode(packagePayload);
    const packageBase64 = Buffer.from(packageBytes).toString("base64");
    const digest = await computePackageDigest(packageBytes);
    const manifestWithDigest = { ...sampleManifest, digest };

    const publishReq = new Request("http://localhost/api/v2/plugins/publish", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        manifest: manifestWithDigest,
        packageBase64,
        channel: "stable",
        signingSecret: "test_secret_123",
      }),
    });

    const res = await worker.fetch(publishReq, env);
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      pluginId: string;
      version: string;
      channel: string;
      packageDigest: string;
      packageR2Key: string;
      signature: string;
      status: string;
    };

    expect(body.pluginId).toBe("conclave.codex");
    expect(body.version).toBe("1.0.0");
    expect(body.channel).toBe("stable");
    expect(body.packageDigest).toBe(digest);
    expect(body.packageR2Key).toContain("plugins/conclave.codex/1.0.0/");
    expect(body.signature).toMatch(/^sig_pkg_/);
    expect(body.status).toBe("published");

    // Verify D1 records
    const pluginRow = db
      .prepare("SELECT * FROM worker_plugins WHERE id = 'conclave.codex'")
      .get() as { display_name: string; status: string };
    expect(pluginRow.display_name).toBe("OpenAI Codex Worker Plugin");
    expect(pluginRow.status).toBe("active");

    const versionRow = db
      .prepare(
        "SELECT * FROM worker_plugin_versions WHERE plugin_id = 'conclave.codex' AND version = '1.0.0'",
      )
      .get() as { channel: string; package_digest: string; is_revoked: number };
    expect(versionRow.channel).toBe("stable");
    expect(versionRow.package_digest).toBe(digest);
    expect(versionRow.is_revoked).toBe(0);

    // Verify R2 object download
    const downloadReq = new Request(
      "http://localhost/api/v2/plugins/conclave.codex/versions/1.0.0/download",
    );
    const downloadRes = await worker.fetch(downloadReq, env);
    expect(downloadRes.status).toBe(200);
    expect(downloadRes.headers.get("content-digest")).toBe(digest);
    const downloadedContent = await downloadRes.text();
    expect(downloadedContent).toBe(packagePayload);
  });

  it("manages multi-channel distributions (stable, beta, development)", async () => {
    const pkg = "console.log('test');";
    const bytes = new TextEncoder().encode(pkg);
    const base64 = Buffer.from(bytes).toString("base64");
    const digest = await computePackageDigest(bytes);

    // 1. Publish stable (1.0.0)
    await worker.fetch(
      new Request("http://localhost/api/v2/plugins/publish", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          manifest: { ...sampleManifest, version: "1.0.0", digest },
          packageBase64: base64,
          channel: "stable",
        }),
      }),
      env,
    );

    // 2. Publish beta (1.1.0-beta.1)
    await worker.fetch(
      new Request("http://localhost/api/v2/plugins/publish", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          manifest: {
            ...sampleManifest,
            version: "1.1.0-beta.1",
            digest,
            channel: "beta",
          },
          packageBase64: base64,
          channel: "beta",
        }),
      }),
      env,
    );

    // 3. Publish dev (2.0.0-dev.1)
    await worker.fetch(
      new Request("http://localhost/api/v2/plugins/publish", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          manifest: {
            ...sampleManifest,
            version: "2.0.0-dev.1",
            digest,
            channel: "development",
          },
          packageBase64: base64,
          channel: "development",
        }),
      }),
      env,
    );

    // Query all plugins
    const allRes = await worker.fetch(
      new Request("http://localhost/api/v2/plugins"),
      env,
    );
    const allBody = (await allRes.json()) as {
      plugins: Array<{
        id: string;
        versions: Array<{ version: string; channel: string }>;
      }>;
    };
    const firstPlugin = allBody.plugins[0]!;
    expect(firstPlugin.versions.length).toBe(3);

    // Query stable only
    const stableRes = await worker.fetch(
      new Request("http://localhost/api/v2/plugins?channel=stable"),
      env,
    );
    const stableBody = (await stableRes.json()) as {
      plugins: Array<{
        versions: Array<{ version: string; channel: string }>;
      }>;
    };
    const stableFirst = stableBody.plugins[0]!;
    expect(stableFirst.versions.length).toBe(1);
    expect(stableFirst.versions[0]!.channel).toBe("stable");

    // Query single plugin detail with latestByChannel mapping
    const detailRes = await worker.fetch(
      new Request("http://localhost/api/v2/plugins/conclave.codex"),
      env,
    );
    const detailBody = (await detailRes.json()) as {
      latestByChannel: Record<string, string>;
      versions: Array<{ version: string }>;
    };
    expect(detailBody.latestByChannel.stable).toBe("1.0.0");
    expect(detailBody.latestByChannel.beta).toBe("1.1.0-beta.1");
    expect(detailBody.latestByChannel.development).toBe("2.0.0-dev.1");
  });

  it("rejects publication with mismatched package digest or invalid signature", async () => {
    const pkg = "console.log('original');";
    const bytes = new TextEncoder().encode(pkg);
    const base64 = Buffer.from(bytes).toString("base64");

    const mismatchReq = new Request("http://localhost/api/v2/plugins/publish", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        manifest: {
          ...sampleManifest,
          digest:
            "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        },
        packageBase64: base64,
      }),
    });

    const mismatchRes = await worker.fetch(mismatchReq, env);
    expect(mismatchRes.status).toBe(400);
    const errBody = (await mismatchRes.json()) as { error: string };
    expect(errBody.error).toMatch(/Package digest mismatch/);

    const forgedSigReq = new Request(
      "http://localhost/api/v2/plugins/publish",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          manifest: {
            ...sampleManifest,
            digest: await computePackageDigest(bytes),
            signature: "sig_pkg_forged_invalid_signature_1234567890abcdef",
          },
          packageBase64: base64,
          signingSecret: "correct_secret",
        }),
      },
    );

    const forgedRes = await worker.fetch(forgedSigReq, env);
    expect(forgedRes.status).toBe(400);
    expect(((await forgedRes.json()) as { error: string }).error).toMatch(
      /Invalid package signature/,
    );
  });

  it("revokes a plugin version and blocks further downloads", async () => {
    const pkg = "console.log('revokable');";
    const bytes = new TextEncoder().encode(pkg);
    const base64 = Buffer.from(bytes).toString("base64");
    const digest = await computePackageDigest(bytes);

    // Publish
    await worker.fetch(
      new Request("http://localhost/api/v2/plugins/publish", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          manifest: { ...sampleManifest, version: "1.0.0", digest },
          packageBase64: base64,
        }),
      }),
      env,
    );

    // Revoke
    const revokeReq = new Request(
      "http://localhost/api/v2/plugins/conclave.codex/versions/1.0.0/revoke",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          reason: "Critical vulnerability discovered in v1.0.0",
        }),
      },
    );
    const revokeRes = await worker.fetch(revokeReq, env);
    expect(revokeRes.status).toBe(200);
    const revokeBody = (await revokeRes.json()) as {
      isRevoked: boolean;
      revocationReason: string;
    };
    expect(revokeBody.isRevoked).toBe(true);
    expect(revokeBody.revocationReason).toBe(
      "Critical vulnerability discovered in v1.0.0",
    );

    // Verify GET version returns revocation info
    const versionRes = await worker.fetch(
      new Request(
        "http://localhost/api/v2/plugins/conclave.codex/versions/1.0.0",
      ),
      env,
    );
    const versionBody = (await versionRes.json()) as {
      isRevoked: boolean;
      revocationReason: string;
    };
    expect(versionBody.isRevoked).toBe(true);
    expect(versionBody.revocationReason).toBe(
      "Critical vulnerability discovered in v1.0.0",
    );

    // Verify download is blocked with 410 Gone
    const downloadRes = await worker.fetch(
      new Request(
        "http://localhost/api/v2/plugins/conclave.codex/versions/1.0.0/download",
      ),
      env,
    );
    expect(downloadRes.status).toBe(410);
  });

  it("deprecates an entire plugin successfully", async () => {
    const pkg = "console.log('deprecate');";
    const bytes = new TextEncoder().encode(pkg);
    const base64 = Buffer.from(bytes).toString("base64");
    const digest = await computePackageDigest(bytes);

    await worker.fetch(
      new Request("http://localhost/api/v2/plugins/publish", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          manifest: { ...sampleManifest, version: "1.0.0", digest },
          packageBase64: base64,
        }),
      }),
      env,
    );

    const deprecateReq = new Request(
      "http://localhost/api/v2/plugins/conclave.codex/deprecate",
      { method: "POST" },
    );
    const deprecateRes = await worker.fetch(deprecateReq, env);
    expect(deprecateRes.status).toBe(200);
    expect(((await deprecateRes.json()) as { status: string }).status).toBe(
      "deprecated",
    );

    const row = db
      .prepare("SELECT status FROM worker_plugins WHERE id = 'conclave.codex'")
      .get() as { status: string };
    expect(row.status).toBe("deprecated");
  });
});
