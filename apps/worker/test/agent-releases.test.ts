import { describe, expect, it, beforeEach } from "vitest";
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import worker from "../src/index.js";
import {
  computePackageDigest,
  signPackageDigest,
} from "../../../packages/security/src/index.js";

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
        httpEtag: `"${key}"`,
      };
    },
    async put(
      key: string,
      value: Uint8Array | ArrayBuffer | string,
      options?: {
        httpMetadata?: Record<string, string>;
        customMetadata?: Record<string, string>;
      },
    ) {
      const body =
        typeof value === "string"
          ? new TextEncoder().encode(value)
          : value instanceof ArrayBuffer
            ? new Uint8Array(value)
            : value;
      storage.set(key, {
        body,
        httpMetadata: options?.httpMetadata,
        customMetadata: options?.customMetadata,
      });
      return {
        key,
        httpEtag: `"${key}"`,
      };
    },
  };
}

describe("Architecture v2 Cloud Agent Releases & Self-Update Registry", () => {
  let db: DatabaseSync;
  let env: Record<string, unknown>;

  const secretKey = "test-agent-release-signing-key";

  beforeEach(() => {
    db = new DatabaseSync(":memory:");
    db.exec("PRAGMA foreign_keys = ON;");
    const sql = fs.readFileSync(schemaPath, "utf8");
    db.exec(sql);

    env = {
      CONCLAVE_ENVIRONMENT: "development",
      CONCLAVE_ALLOW_ANONYMOUS_DEV: "true",
      CONCLAVE_SECURITY_KEY: secretKey,
      CONCLAVE_DB: createD1Mock(db),
      CONCLAVE_STORAGE: createR2Mock(),
    };
  });

  it("publishes a signed agent release and serves it via download endpoint", async () => {
    const packageArchive = new TextEncoder().encode(
      "conclave-agent-v1.3.0-binary-bundle",
    );
    const expectedDigest = await computePackageDigest(packageArchive);
    const expectedSignature = await signPackageDigest(
      expectedDigest,
      secretKey,
    );

    const publishRes = await worker.fetch(
      new Request("https://conclave.test/api/v2/agent-releases/publish", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-conclave-workspace-id": "ws-dev",
          "x-conclave-user-id": "user-dev",
          "x-conclave-user-role": "owner",
        },
        body: JSON.stringify({
          version: "1.3.0",
          channel: "stable",
          minSupportedAgentVersion: "1.0.0",
          supportedOS: ["macos", "linux"],
          supportedArch: ["arm64", "x64"],
          releaseNotes: "Performance improvements and self-update support",
          packageBase64: Buffer.from(packageArchive).toString("base64"),
          packageDigest: expectedDigest,
          signature: expectedSignature,
        }),
      }),
      env as never,
    );

    expect(publishRes.status).toBe(201);
    const publishData = (await publishRes.json()) as {
      version: string;
      channel: string;
      packageDigest: string;
      signature: string;
      status: string;
    };
    expect(publishData.version).toBe("1.3.0");
    expect(publishData.channel).toBe("stable");
    expect(publishData.packageDigest).toBe(expectedDigest);
    expect(publishData.signature).toBe(expectedSignature);

    // Verify metadata endpoint
    const metaRes = await worker.fetch(
      new Request("https://conclave.test/api/v2/agent-releases/1.3.0"),
      env as never,
    );
    expect(metaRes.status).toBe(200);
    const metaData = (await metaRes.json()) as {
      version: string;
      channel: string;
      supportedOS: string[];
      isRevoked: boolean;
    };
    expect(metaData.version).toBe("1.3.0");
    expect(metaData.channel).toBe("stable");
    expect(metaData.supportedOS).toEqual(["macos", "linux"]);
    expect(metaData.isRevoked).toBe(false);

    // Verify download endpoint
    const downloadRes = await worker.fetch(
      new Request("https://conclave.test/api/v2/agent-releases/1.3.0/download"),
      env as never,
    );
    expect(downloadRes.status).toBe(200);
    expect(downloadRes.headers.get("content-digest")).toBe(expectedDigest);
    const downloadedText = await downloadRes.text();
    expect(downloadedText).toBe("conclave-agent-v1.3.0-binary-bundle");
  });

  it("checks for latest updates based on channel, OS, arch, and currentVersion", async () => {
    const pkg1 = new TextEncoder().encode("agent-1.2.0");
    const pkg2 = new TextEncoder().encode("agent-1.3.0");
    const pkgBeta = new TextEncoder().encode("agent-1.4.0-beta");

    // Publish 1.2.0 (stable)
    await worker.fetch(
      new Request("https://conclave.test/api/v2/agent-releases/publish", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          version: "1.2.0",
          channel: "stable",
          supportedOS: ["macos", "linux"],
          supportedArch: ["arm64", "x64"],
          packageBase64: Buffer.from(pkg1).toString("base64"),
        }),
      }),
      env as never,
    );

    // Publish 1.3.0 (stable)
    await worker.fetch(
      new Request("https://conclave.test/api/v2/agent-releases/publish", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          version: "1.3.0",
          channel: "stable",
          supportedOS: ["macos", "linux"],
          supportedArch: ["arm64", "x64"],
          packageBase64: Buffer.from(pkg2).toString("base64"),
        }),
      }),
      env as never,
    );

    // Publish 1.4.0 (beta)
    await worker.fetch(
      new Request("https://conclave.test/api/v2/agent-releases/publish", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          version: "1.4.0",
          channel: "beta",
          supportedOS: ["macos"],
          supportedArch: ["arm64"],
          packageBase64: Buffer.from(pkgBeta).toString("base64"),
        }),
      }),
      env as never,
    );

    // Query latest stable from agent 1.2.0 -> updateAvailable: true (1.3.0)
    const check1 = await worker.fetch(
      new Request(
        "https://conclave.test/api/v2/agent-releases/latest?channel=stable&currentVersion=1.2.0&os=macos&arch=arm64",
      ),
      env as never,
    );
    expect(check1.status).toBe(200);
    const data1 = (await check1.json()) as {
      updateAvailable: boolean;
      release: { version: string };
    };
    expect(data1.updateAvailable).toBe(true);
    expect(data1.release.version).toBe("1.3.0");

    // Query latest stable from agent 1.3.0 -> updateAvailable: false (already latest stable)
    const check2 = await worker.fetch(
      new Request(
        "https://conclave.test/api/v2/agent-releases/latest?channel=stable&currentVersion=1.3.0&os=macos&arch=arm64",
      ),
      env as never,
    );
    expect(check2.status).toBe(200);
    const data2 = (await check2.json()) as {
      updateAvailable: boolean;
      release: { version: string };
    };
    expect(data2.updateAvailable).toBe(false);
    expect(data2.release.version).toBe("1.3.0");

    // Query beta channel from agent 1.3.0 -> updateAvailable: true (1.4.0 beta)
    const checkBeta = await worker.fetch(
      new Request(
        "https://conclave.test/api/v2/agent-releases/latest?channel=beta&currentVersion=1.3.0&os=macos&arch=arm64",
      ),
      env as never,
    );
    expect(checkBeta.status).toBe(200);
    const dataBeta = (await checkBeta.json()) as {
      updateAvailable: boolean;
      release: { version: string };
    };
    expect(dataBeta.updateAvailable).toBe(true);
    expect(dataBeta.release.version).toBe("1.4.0");

    // Query beta on windows -> not found / no compatible beta
    const checkBetaWin = await worker.fetch(
      new Request(
        "https://conclave.test/api/v2/agent-releases/latest?channel=beta&currentVersion=1.3.0&os=windows&arch=arm64",
      ),
      env as never,
    );
    expect(checkBetaWin.status).toBe(200);
    const dataBetaWin = (await checkBetaWin.json()) as {
      updateAvailable: boolean;
      release: unknown;
    };
    expect(dataBetaWin.updateAvailable).toBe(false);
    expect(dataBetaWin.release).toBeNull();
  });

  it("handles cryptographic verification and rejects forged signatures", async () => {
    const pkg = new TextEncoder().encode("agent-1.5.0");
    const digest = await computePackageDigest(pkg);

    const res = await worker.fetch(
      new Request("https://conclave.test/api/v2/agent-releases/publish", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          version: "1.5.0",
          channel: "stable",
          packageBase64: Buffer.from(pkg).toString("base64"),
          packageDigest: digest,
          signature: "sig_pkg_forged_invalid_signature_hex",
        }),
      }),
      env as never,
    );

    expect(res.status).toBe(400);
    const err = (await res.json()) as { error: string };
    expect(err.error).toMatch(/Invalid package signature/i);
  });

  it("revokes an agent release and blocks subsequent downloads with 410 Gone", async () => {
    const pkg = new TextEncoder().encode("agent-1.6.0-buggy");
    await worker.fetch(
      new Request("https://conclave.test/api/v2/agent-releases/publish", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          version: "1.6.0",
          channel: "stable",
          packageBase64: Buffer.from(pkg).toString("base64"),
        }),
      }),
      env as never,
    );

    // Revoke release
    const revokeRes = await worker.fetch(
      new Request("https://conclave.test/api/v2/agent-releases/1.6.0/revoke", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          reason: "Critical startup crash on linux-arm64",
        }),
      }),
      env as never,
    );
    expect(revokeRes.status).toBe(200);
    const revokeData = (await revokeRes.json()) as {
      isRevoked: boolean;
      revocationReason: string;
    };
    expect(revokeData.isRevoked).toBe(true);
    expect(revokeData.revocationReason).toBe(
      "Critical startup crash on linux-arm64",
    );

    // Download should return 410 Gone
    const downloadRes = await worker.fetch(
      new Request("https://conclave.test/api/v2/agent-releases/1.6.0/download"),
      env as never,
    );
    expect(downloadRes.status).toBe(410);
    const errData = (await downloadRes.json()) as {
      error: string;
      revocationReason: string;
    };
    expect(errData.error).toMatch(/revoked/i);
    expect(errData.revocationReason).toBe(
      "Critical startup crash on linux-arm64",
    );

    // Check latest should ignore revoked version
    const checkRes = await worker.fetch(
      new Request(
        "https://conclave.test/api/v2/agent-releases/latest?channel=stable",
      ),
      env as never,
    );
    expect(checkRes.status).toBe(200);
    const checkData = (await checkRes.json()) as { release: unknown };
    expect(checkData.release).toBeNull();
  });

  it("requires authentication for release downloads outside development", async () => {
    const productionEnv = {
      ...env,
      CONCLAVE_ENVIRONMENT: "production",
      CONCLAVE_ALLOW_ANONYMOUS_DEV: undefined,
    };
    const response = await worker.fetch(
      new Request("https://conclave.test/api/v2/agent-releases/1.3.0/download"),
      productionEnv as never,
    );
    expect(response.status).toBe(401);
  });
});
