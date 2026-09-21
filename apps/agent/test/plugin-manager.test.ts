import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { computePackageDigest, signPackageDigest } from "@conclave/security";
import type { WorkerPluginManifest } from "@conclave/plugin-sdk";
import type { DesiredWorker } from "@conclave/agent-protocol";
import { loadAgentConfig } from "../src/config.js";
import { AgentStorage } from "../src/storage.js";
import { AgentLogger } from "../src/logger.js";
import { WorkerManager } from "../src/worker-manager.js";
import { PluginManager } from "../src/plugin-manager.js";

describe("PluginManager", () => {
  let tmpDir: string;
  const testSigningKey = "test-plugin-signing-secret-12345";

  beforeEach(() => {
    tmpDir = path.join(
      os.tmpdir(),
      `agent-plugin-test-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
    );
    fs.mkdirSync(tmpDir, { recursive: true });
  });

  afterEach(() => {
    vi.restoreAllMocks();
    try {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    } catch {
      // ignore
    }
  });

  function createTestManifest(
    pluginId: string,
    version: string,
  ): WorkerPluginManifest {
    return {
      pluginId,
      version,
      displayName: `Plugin ${pluginId}`,
      description: "Test Worker Plugin",
      publisher: "Conclave Inc",
      channel: "stable",
      protocolVersion: "2.0",
      minimumAgentVersion: "0.1.0",
      supportedOS: ["macos", "linux", "windows"],
      supportedArchitecture: ["arm64", "x64"],
      roles: ["implementer", "reviewer"],
      capabilities: ["code_execution"],
      permissions: ["fs.read", "fs.write"],
      configurationSchema: {},
      secretSchema: {},
      entrypoint: "index.js",
      billingModes: ["free"],
      digest: "test-digest",
      signature: "test-sig",
    };
  }

  it("lists installed plugins and resolves semver policies correctly", () => {
    const config = loadAgentConfig({ homeDir: tmpDir });
    const storage = new AgentStorage(config);
    const logger = new AgentLogger(config.logDir);
    const manager = new PluginManager(
      config,
      storage,
      logger,
      undefined,
      testSigningKey,
    );

    // Seed installed versions for 'codex'
    const codex140 = storage.getPluginDir("codex", "1.4.0");
    const codex150 = storage.getPluginDir("codex", "1.5.0");
    const codex200 = storage.getPluginDir("codex", "2.0.0");
    fs.mkdirSync(codex140, { recursive: true });
    fs.mkdirSync(codex150, { recursive: true });
    fs.mkdirSync(codex200, { recursive: true });

    const installed = manager.listInstalledPlugins();
    expect(installed.has("codex")).toBe(true);
    expect(installed.get("codex")).toEqual(["2.0.0", "1.5.0", "1.4.0"]);

    expect(manager.resolveLocalVersion("codex", "^1.4")).toBe("1.5.0");
    expect(manager.resolveLocalVersion("codex", "~1.4.0")).toBe("1.4.0");
    expect(manager.resolveLocalVersion("codex", ">=2.0.0")).toBe("2.0.0");
    expect(manager.resolveLocalVersion("codex", "^3.0.0")).toBeNull();
  });

  it("provisions a missing plugin via download, signature verification, staging, and activation", async () => {
    const config = loadAgentConfig({
      homeDir: tmpDir,
      cloudUrl: "https://cloud.conclave.test",
    });
    const storage = new AgentStorage(config);
    const logger = new AgentLogger(config.logDir);
    const manager = new PluginManager(
      config,
      storage,
      logger,
      undefined,
      testSigningKey,
    );

    const pluginCode =
      "export async function execute(ctx) { return { status: 'completed' }; }";
    const packageBuffer = Buffer.from(pluginCode, "utf8");
    const digest = await computePackageDigest(packageBuffer);
    const signature = await signPackageDigest(digest, testSigningKey);

    const manifest = createTestManifest("echo-plugin", "1.0.0");
    manifest.digest = digest;
    manifest.signature = signature;

    // Mock fetch for metadata and package download
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.endsWith("/api/v2/plugins/echo-plugin")) {
        return new Response(
          JSON.stringify({
            plugin: {
              id: "echo-plugin",
              displayName: "Echo Plugin",
              description: "Deterministic echo worker plugin",
              publisher: "Conclave",
              status: "published",
            },
            versions: [
              {
                id: "pv-1",
                pluginId: "echo-plugin",
                version: "1.0.0",
                channel: "stable",
                protocolVersion: "2.0",
                minAgentVersion: "0.1.0",
                supportedOS: ["macos", "linux", "windows"],
                supportedArch: ["arm64", "x64"],
                packageDigest: digest,
                packageR2Key: "plugins/echo-plugin/1.0.0.bin",
                signature,
                isRevoked: false,
              },
            ],
            latestByChannel: { stable: "1.0.0" },
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (url.includes("/versions/1.0.0/download")) {
        return new Response(packageBuffer, {
          status: 200,
          headers: { "Content-Type": "application/octet-stream" },
        });
      }
      return new Response("Not found", { status: 404 });
    });

    vi.stubGlobal("fetch", fetchMock);

    const phases: string[] = [];
    const provisioned = await manager.ensurePlugin("echo-plugin", "^1.0", {
      channel: "stable",
      onPhaseChange: (phase) => phases.push(phase),
    });

    expect(provisioned.pluginId).toBe("echo-plugin");
    expect(provisioned.version).toBe("1.0.0");
    expect(
      fs.existsSync(path.join(provisioned.pluginDir, "manifest.json")),
    ).toBe(true);
    expect(phases).toContain("downloading");
    expect(phases).toContain("verifying");
    expect(phases).toContain("activating");
    expect(phases).toContain("completed");
  });

  it("upgrades an outdated plugin, drains active tasks, activates, and handles rollback on broken health check", async () => {
    const config = loadAgentConfig({
      homeDir: tmpDir,
      cloudUrl: "https://cloud.conclave.test",
    });
    const storage = new AgentStorage(config);
    const logger = new AgentLogger(config.logDir);
    const workerManager = new WorkerManager(config, storage, logger);
    const manager = new PluginManager(
      config,
      storage,
      logger,
      workerManager,
      testSigningKey,
    );

    // 1. Seed v1.0.0 installed locally
    const v1Dir = storage.getPluginDir("codex", "1.0.0");
    fs.mkdirSync(v1Dir, { recursive: true });
    const v1Manifest = createTestManifest("codex", "1.0.0");
    fs.writeFileSync(
      path.join(v1Dir, "manifest.json"),
      JSON.stringify(v1Manifest),
    );
    fs.writeFileSync(
      path.join(v1Dir, "index.js"),
      "export async function execute() {}",
    );

    const newCode = "broken entrypoint script";
    const newBuffer = Buffer.from(newCode, "utf8");
    const newDigest = await computePackageDigest(newBuffer);
    const newSignature = await signPackageDigest(newDigest, testSigningKey);

    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.endsWith("/api/v2/plugins/codex")) {
        return new Response(
          JSON.stringify({
            plugin: {
              id: "codex",
              displayName: "Codex Plugin",
              description: "Codex Runner",
              publisher: "Conclave",
              status: "published",
            },
            versions: [
              {
                id: "pv-2",
                pluginId: "codex",
                version: "1.5.0",
                channel: "stable",
                protocolVersion: "2.0",
                minAgentVersion: "0.1.0",
                supportedOS: ["macos", "linux", "windows"],
                supportedArch: ["arm64", "x64"],
                packageDigest: newDigest,
                packageR2Key: "plugins/codex/1.5.0.bin",
                signature: newSignature,
                isRevoked: false,
              },
              {
                id: "pv-1",
                pluginId: "codex",
                version: "1.0.0",
                channel: "stable",
                protocolVersion: "2.0",
                minAgentVersion: "0.1.0",
                supportedOS: ["macos", "linux", "windows"],
                supportedArch: ["arm64", "x64"],
                packageDigest: "old-digest",
                packageR2Key: "plugins/codex/1.0.0.bin",
                signature: "old-sig",
                isRevoked: false,
              },
            ],
            latestByChannel: { stable: "1.5.0" },
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (url.includes("/versions/1.5.0/download")) {
        return new Response(newBuffer, { status: 200 });
      }
      return new Response("Not found", { status: 404 });
    });

    vi.stubGlobal("fetch", fetchMock);

    const phases: string[] = [];
    // Health check returns false on new version
    await expect(
      manager.ensurePlugin("codex", "^1.4", {
        channel: "stable",
        customHealthCheck: async () => false,
        onPhaseChange: (p) => phases.push(p),
      }),
    ).rejects.toThrow(/failed health check/);

    expect(phases).toContain("draining");
    expect(phases).toContain("rolled_back");

    // Check active.json rolled back to 1.0.0
    const activeFile = path.join(config.pluginDir, "codex", "active.json");
    const activeData = JSON.parse(fs.readFileSync(activeFile, "utf8"));
    expect(activeData.activeVersion).toBe("1.0.0");
    expect(activeData.rolledBack).toBe(true);
  });

  it("supports multiple workers sharing the same plugin with different configurations", () => {
    const config = loadAgentConfig({ homeDir: tmpDir });
    const storage = new AgentStorage(config);
    const logger = new AgentLogger(config.logDir);
    const workerManager = new WorkerManager(config, storage, logger);
    const manager = new PluginManager(
      config,
      storage,
      logger,
      workerManager,
      testSigningKey,
    );
    workerManager.setPluginManager(manager);

    // Seed installed plugin
    const codexDir = storage.getPluginDir("codex", "1.4.0");
    fs.mkdirSync(codexDir, { recursive: true });
    const codexManifest = createTestManifest("codex", "1.4.0");
    fs.writeFileSync(
      path.join(codexDir, "manifest.json"),
      JSON.stringify(codexManifest),
    );
    fs.writeFileSync(
      path.join(codexDir, "index.js"),
      "export async function execute() {}",
    );

    const worker1: DesiredWorker = {
      workerId: "w-codex-main",
      pluginId: "codex",
      pluginVersionPolicy: "^1.0",
      name: "Codex Main",
      roles: ["coder"],
      capabilities: ["code_write"],
      config: { temperature: 0.2, model: "o3-mini" },
      secretRefs: [],
      billingMode: "local_compute",
      independenceKey: "key-1",
      concurrencyLimit: 2,
      enabled: true,
    };

    const worker2: DesiredWorker = {
      workerId: "w-codex-reviewer",
      pluginId: "codex",
      pluginVersionPolicy: "1.4.0",
      name: "Codex Reviewer",
      roles: ["reviewer"],
      capabilities: ["code_review"],
      config: { temperature: 0.0, model: "o1" },
      secretRefs: [],
      billingMode: "local_compute",
      independenceKey: "key-2",
      concurrencyLimit: 4,
      enabled: true,
    };

    workerManager.configureWorker(worker1);
    workerManager.configureWorker(worker2);

    expect(workerManager.listWorkers().length).toBe(2);
    expect(workerManager.getWorker("w-codex-main")?.config).toEqual({
      temperature: 0.2,
      model: "o3-mini",
    });
    expect(workerManager.getWorker("w-codex-reviewer")?.config).toEqual({
      temperature: 0.0,
      model: "o1",
    });

    // Both workers resolve to the same local plugin directory
    const resolvedVer1 = manager.resolveLocalVersion(
      worker1.pluginId,
      worker1.pluginVersionPolicy,
    );
    const resolvedVer2 = manager.resolveLocalVersion(
      worker2.pluginId,
      worker2.pluginVersionPolicy,
    );
    expect(resolvedVer1).toBe("1.4.0");
    expect(resolvedVer2).toBe("1.4.0");
  });
});
