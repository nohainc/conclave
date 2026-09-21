import fs from "node:fs";
import path from "node:path";
import type { AgentConfig } from "./config.js";

export class AgentStorage {
  constructor(private readonly config: AgentConfig) {}

  ensureDirectories(): void {
    fs.mkdirSync(this.config.homeDir, { recursive: true });
    fs.mkdirSync(this.config.workDir, { recursive: true });
    fs.mkdirSync(this.config.pluginDir, { recursive: true });
    fs.mkdirSync(this.config.journalDir, { recursive: true });
    fs.mkdirSync(this.config.logDir, { recursive: true });
  }

  getWorkDir(runId: string, taskId: string): string {
    const dir = path.join(this.config.workDir, runId, taskId);
    fs.mkdirSync(dir, { recursive: true });
    return dir;
  }

  cleanupWorkDir(runId: string, taskId?: string): void {
    const target = taskId
      ? path.join(this.config.workDir, runId, taskId)
      : path.join(this.config.workDir, runId);
    if (fs.existsSync(target)) {
      try {
        fs.rmSync(target, { recursive: true, force: true });
      } catch {
        // ignore cleanup error
      }
    }
  }

  getPluginDir(pluginId: string, version: string): string {
    const dir = path.join(this.config.pluginDir, pluginId, version);
    fs.mkdirSync(dir, { recursive: true });
    return dir;
  }
}
