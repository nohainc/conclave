import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { loadAgentConfig } from "../src/config.js";
import { AgentJournal } from "../src/journal.js";

describe("AgentJournal", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = path.join(os.tmpdir(), `agent-journal-test-${Date.now()}`);
    fs.mkdirSync(tmpDir, { recursive: true });
  });

  afterEach(() => {
    try {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    } catch {
      // ignore
    }
  });

  it("records assignment lifecycle, persists to disk and reloads cleanly", () => {
    const config = loadAgentConfig({ homeDir: tmpDir });
    const journal1 = new AgentJournal(config);

    journal1.recordStart("asg-1", "att-1", "idem-1");
    expect(journal1.get("asg-1")?.status).toBe("running");
    expect(journal1.getUnreconciled().length).toBe(0);

    journal1.recordResult("asg-1", { summary: "Done" }, "completed");
    expect(journal1.get("asg-1")?.status).toBe("completed");
    expect(journal1.getUnreconciled().length).toBe(1);

    // Reload in separate instance
    const journal2 = new AgentJournal(config);
    journal2.load();

    const reloaded = journal2.get("asg-1");
    expect(reloaded).toBeDefined();
    expect(reloaded?.status).toBe("completed");
    expect(reloaded?.terminalResult).toEqual({ summary: "Done" });

    journal2.acknowledge("asg-1");
    expect(journal2.get("asg-1")).toBeUndefined();
    expect(journal2.list().length).toBe(0);
  });
});
