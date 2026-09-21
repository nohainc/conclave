import fs from "node:fs/promises";
import path from "node:path";
import type { AgentConfig } from "./config.js";
import { MacOSLaunchAgentService } from "./service-manager.js";

export async function installMacOSAgent(config: AgentConfig, executable: string): Promise<void> {
  await fs.mkdir(config.homeDir, { recursive: true });
  await fs.mkdir(config.logDir, { recursive: true });
  await new MacOSLaunchAgentService().install({
    executable: path.resolve(executable),
    homeDir: config.homeDir,
    logDir: config.logDir,
  });
}

export async function uninstallMacOSAgent(): Promise<void> {
  await new MacOSLaunchAgentService().uninstall();
}

