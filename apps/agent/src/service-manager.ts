import { execFile as nodeExecFile } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

const execFile = promisify(nodeExecFile);
export const LAUNCH_AGENT_LABEL = "com.conclaveax.agent";

export function launchAgentPlist(options: {
  executable: string;
  homeDir: string;
  logDir: string;
}): string {
  const escape = (value: string) =>
    value
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;");
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${LAUNCH_AGENT_LABEL}</string>
  <key>ProgramArguments</key><array><string>${escape(options.executable)}</string><string>start</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>EnvironmentVariables</key><dict><key>CONCLAVE_AGENT_HOME</key><string>${escape(options.homeDir)}</string></dict>
  <key>StandardOutPath</key><string>${escape(path.join(options.logDir, "launchd.stdout.log"))}</string>
  <key>StandardErrorPath</key><string>${escape(path.join(options.logDir, "launchd.stderr.log"))}</string>
</dict></plist>`;
}

export class MacOSLaunchAgentService {
  readonly plistPath = path.join(
    os.homedir(),
    "Library",
    "LaunchAgents",
    `${LAUNCH_AGENT_LABEL}.plist`,
  );

  private assertMacOS(): void {
    if (process.platform !== "darwin")
      throw new Error("launchd is available only on macOS");
  }

  async install(options: {
    executable: string;
    homeDir: string;
    logDir: string;
  }): Promise<void> {
    this.assertMacOS();
    await fs.mkdir(path.dirname(this.plistPath), { recursive: true });
    await fs.mkdir(options.logDir, { recursive: true });
    await fs.writeFile(this.plistPath, launchAgentPlist(options), {
      mode: 0o600,
    });
    await this.unloadIfPresent();
    await execFile("launchctl", [
      "bootstrap",
      `gui/${process.getuid?.() ?? ""}`,
      this.plistPath,
    ]);
  }

  async uninstall(): Promise<void> {
    this.assertMacOS();
    await this.unloadIfPresent();
    await fs.rm(this.plistPath, { force: true });
  }

  async status(): Promise<string> {
    this.assertMacOS();
    try {
      const result = await execFile("launchctl", [
        "print",
        `gui/${process.getuid?.() ?? ""}/${LAUNCH_AGENT_LABEL}`,
      ]);
      return result.stdout;
    } catch {
      return "not running";
    }
  }

  private async unloadIfPresent(): Promise<void> {
    await execFile("launchctl", [
      "bootout",
      `gui/${process.getuid?.() ?? ""}/${LAUNCH_AGENT_LABEL}`,
    ]).catch(() => undefined);
  }
}
