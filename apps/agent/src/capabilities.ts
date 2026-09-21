import os from "node:os";
import { execSync } from "node:child_process";
import type { AgentCapabilities } from "@conclave/agent-protocol";

export const AGENT_VERSION = "0.2.0";

export function detectHostPlatform(): "macos" | "linux" | "windows" {
  const platform = os.platform();
  if (platform === "darwin") return "macos";
  if (platform === "win32") return "windows";
  return "linux";
}

export function detectHostArchitecture(): "arm64" | "x64" {
  const arch = os.arch();
  if (arch === "arm64") return "arm64";
  return "x64";
}

export function detectInstalledRuntimes(): readonly string[] {
  const runtimes: string[] = [];
  const checks: Record<string, string> = {
    node: "node --version",
    git: "git --version",
    python3: "python3 --version",
    python: "python --version",
    cargo: "cargo --version",
    flutter: "flutter --version",
    docker: "docker --version",
  };

  for (const [runtime, command] of Object.entries(checks)) {
    try {
      execSync(command, { stdio: "ignore", timeout: 1000 });
      runtimes.push(runtime);
    } catch {
      // Runtime not installed or timed out
    }
  }

  return runtimes;
}

export function detectAgentCapabilities(options?: {
  maxConcurrentWorkers?: number;
  customCapabilities?: readonly string[];
}): AgentCapabilities {
  const cpuCount = os.cpus().length || 4;
  const maxConcurrent = options?.maxConcurrentWorkers ?? Math.max(1, cpuCount);

  return {
    os: detectHostPlatform(),
    arch: detectHostArchitecture(),
    agentVersion: AGENT_VERSION,
    supportedRuntimes: [...detectInstalledRuntimes()],
    maxConcurrentWorkers: maxConcurrent,
    ...(options?.customCapabilities
      ? { customCapabilities: [...options.customCapabilities] }
      : {}),
  };
}

export const resolveHostCapabilities = detectAgentCapabilities;
