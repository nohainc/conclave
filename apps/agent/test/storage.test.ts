import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { loadAgentConfig } from "../src/config.js";
import { AgentStorage } from "../src/storage.js";

describe("AgentStorage", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = path.join(os.tmpdir(), `agent-storage-test-${Date.now()}`);
    fs.mkdirSync(tmpDir, { recursive: true });
  });

  afterEach(() => {
    try {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    } catch {
      // ignore
    }
  });

  it("ensures all directories are created and cleans up work directories", () => {
    const config = loadAgentConfig({ homeDir: tmpDir });
    const storage = new AgentStorage(config);

    storage.ensureDirectories();

    expect(fs.existsSync(config.workDir)).toBe(true);
    expect(fs.existsSync(config.pluginDir)).toBe(true);
    expect(fs.existsSync(config.journalDir)).toBe(true);
    expect(fs.existsSync(config.logDir)).toBe(true);

    const taskWorkDir = storage.getWorkDir("run-1", "task-1");
    expect(fs.existsSync(taskWorkDir)).toBe(true);

    storage.cleanupWorkDir("run-1", "task-1");
    expect(fs.existsSync(taskWorkDir)).toBe(false);
  });
});
