import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { AgentLogger } from "../src/logger.js";

describe("AgentLogger", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = path.join(
      os.tmpdir(),
      `agent-logger-test-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`,
    );
    fs.mkdirSync(tmpDir, { recursive: true });
  });

  afterEach(() => {
    try {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    } catch {
      // ignore
    }
  });

  it("redacts sensitive auth tokens, bearer tokens and API keys", () => {
    expect(AgentLogger.redact("Bearer conclave_sec_1234567890abcdef")).toBe(
      "Bearer [REDACTED]",
    );
    expect(AgentLogger.redact("key: sk-proj-1234567890abcdef123456")).toBe(
      "key: sk-[REDACTED]",
    );
    expect(AgentLogger.redact("token: tok_live_abcdef1234567890")).toBe(
      "token: tok_[REDACTED]",
    );
  });

  it("writes logs with redactions to disk file", () => {
    const logger = new AgentLogger(tmpDir);
    logger.info("Test message with secret Bearer conclave_sec_secret123", {
      token: "tok_secret_999",
    });

    const files = fs.readdirSync(tmpDir);
    expect(files.length).toBeGreaterThan(0);
    const logFile = files[0];
    expect(logFile).toBeDefined();
    const logContent = fs.readFileSync(path.join(tmpDir, logFile!), "utf8");
    expect(logContent).toContain("Test message with secret Bearer [REDACTED]");
    expect(logContent).not.toContain("conclave_sec_secret123");
    expect(logContent).not.toContain("tok_secret_999");
  });
});
