import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { loadAgentConfig, saveAgentConfig } from "../src/config.js";

describe("AgentConfig", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = path.join(os.tmpdir(), `agent-config-test-${Date.now()}`);
    fs.mkdirSync(tmpDir, { recursive: true });
  });

  afterEach(() => {
    try {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    } catch {
      // ignore
    }
  });

  it("loads default config with sane fallbacks", () => {
    const config = loadAgentConfig({ homeDir: tmpDir }, {});
    expect(config.homeDir).toBe(path.resolve(tmpDir));
    expect(config.workspaceId).toBe("default");
    expect(config.cloudUrl).toBe("http://localhost:8787");
    expect(config.maxConcurrentWorkers).toBeGreaterThanOrEqual(1);
    expect(config.heartbeatIntervalMs).toBe(15000);
  });

  it("saves and reloads config from JSON file", () => {
    const original = loadAgentConfig({
      homeDir: tmpDir,
      workspaceId: "ws-test-123",
      agentId: "agent-custom",
      name: "Custom Runner",
      cloudUrl: "https://cloud.conclave.ai",
      agentToken: "sec_tok_123",
      maxConcurrentWorkers: 8,
      heartbeatIntervalMs: 20000,
    });

    saveAgentConfig(original);

    const reloaded = loadAgentConfig({ homeDir: tmpDir }, {});
    expect(reloaded.workspaceId).toBe("ws-test-123");
    expect(reloaded.agentId).toBe("agent-custom");
    expect(reloaded.name).toBe("Custom Runner");
    expect(reloaded.cloudUrl).toBe("https://cloud.conclave.ai");
    expect(reloaded.agentToken).toBe("sec_tok_123");
    expect(reloaded.maxConcurrentWorkers).toBe(8);
    expect(reloaded.heartbeatIntervalMs).toBe(20000);
  });
});
