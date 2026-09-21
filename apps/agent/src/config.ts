import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { readMacOSCredentialSync } from "./credentials.js";

export interface AgentConfig {
  readonly workspaceId: string;
  readonly agentId: string;
  readonly name: string;
  readonly cloudUrl: string;
  readonly agentToken: string;
  readonly homeDir: string;
  readonly workDir: string;
  readonly pluginDir: string;
  readonly journalDir: string;
  readonly logDir: string;
  readonly maxConcurrentWorkers: number;
  readonly heartbeatIntervalMs: number;
  readonly pollIntervalMs: number;
}

export function defaultAgentHomeDir(): string {
  const envHome = process.env.CONCLAVE_AGENT_HOME || process.env.CONCLAVE_HOME;
  if (envHome) return path.resolve(envHome);
  return path.join(os.homedir(), ".conclave", "agent");
}

export function loadAgentConfig(
  options?: Partial<AgentConfig>,
  env: Record<string, string | undefined> = process.env,
): AgentConfig {
  const homeDir =
    options?.homeDir ?? env.CONCLAVE_AGENT_HOME ?? defaultAgentHomeDir();

  let fileConfig: Record<string, unknown> = {};
  const configPath = path.join(homeDir, "conclave-agent.json");
  if (fs.existsSync(configPath)) {
    try {
      const raw = fs.readFileSync(configPath, "utf8");
      fileConfig = JSON.parse(raw) as Record<string, unknown>;
    } catch {
      fileConfig = {};
    }
  }

  const workspaceId =
    options?.workspaceId ??
    (typeof fileConfig.workspaceId === "string"
      ? fileConfig.workspaceId
      : undefined) ??
    env.CONCLAVE_WORKSPACE_ID ??
    "default";

  const agentId =
    options?.agentId ??
    (typeof fileConfig.agentId === "string" ? fileConfig.agentId : undefined) ??
    env.CONCLAVE_AGENT_ID ??
    `agent-${os
      .hostname()
      .toLowerCase()
      .replace(/[^a-z0-9_-]/g, "-")}`;

  const name =
    options?.name ??
    (typeof fileConfig.name === "string" ? fileConfig.name : undefined) ??
    env.CONCLAVE_AGENT_NAME ??
    `Agent ${os.hostname()}`;

  const cloudUrl =
    options?.cloudUrl ??
    (typeof fileConfig.cloudUrl === "string"
      ? fileConfig.cloudUrl
      : undefined) ??
    env.CONCLAVE_CLOUD_URL ??
    "http://localhost:8787";

  const agentToken =
    options?.agentToken ??
    (typeof fileConfig.agentToken === "string"
      ? fileConfig.agentToken
      : undefined) ??
    env.CONCLAVE_AGENT_TOKEN ??
    readMacOSCredentialSync(agentId) ??
    "";

  const workDir =
    options?.workDir ??
    (typeof fileConfig.workDir === "string" ? fileConfig.workDir : undefined) ??
    env.CONCLAVE_WORK_DIR ??
    path.join(homeDir, "work");

  const pluginDir =
    options?.pluginDir ??
    (typeof fileConfig.pluginDir === "string"
      ? fileConfig.pluginDir
      : undefined) ??
    env.CONCLAVE_PLUGIN_DIR ??
    path.join(homeDir, "plugins");

  const journalDir =
    options?.journalDir ??
    (typeof fileConfig.journalDir === "string"
      ? fileConfig.journalDir
      : undefined) ??
    env.CONCLAVE_JOURNAL_DIR ??
    path.join(homeDir, "journal");

  const logDir =
    options?.logDir ??
    (typeof fileConfig.logDir === "string" ? fileConfig.logDir : undefined) ??
    env.CONCLAVE_LOG_DIR ??
    path.join(homeDir, "logs");

  const maxConcurrentWorkers =
    options?.maxConcurrentWorkers ??
    (typeof fileConfig.maxConcurrentWorkers === "number"
      ? fileConfig.maxConcurrentWorkers
      : undefined) ??
    (env.CONCLAVE_MAX_CONCURRENT_WORKERS
      ? parseInt(env.CONCLAVE_MAX_CONCURRENT_WORKERS, 10)
      : undefined) ??
    Math.max(1, os.cpus().length || 4);

  const heartbeatIntervalMs =
    options?.heartbeatIntervalMs ??
    (typeof fileConfig.heartbeatIntervalMs === "number"
      ? fileConfig.heartbeatIntervalMs
      : undefined) ??
    (env.CONCLAVE_HEARTBEAT_INTERVAL_MS
      ? parseInt(env.CONCLAVE_HEARTBEAT_INTERVAL_MS, 10)
      : undefined) ??
    15000;

  const pollIntervalMs =
    options?.pollIntervalMs ??
    (typeof fileConfig.pollIntervalMs === "number"
      ? fileConfig.pollIntervalMs
      : undefined) ??
    (env.CONCLAVE_POLL_INTERVAL_MS
      ? parseInt(env.CONCLAVE_POLL_INTERVAL_MS, 10)
      : undefined) ??
    2000;

  return {
    workspaceId,
    agentId,
    name,
    cloudUrl: cloudUrl.replace(/\/+$/, ""),
    agentToken,
    homeDir: path.resolve(homeDir),
    workDir: path.resolve(workDir),
    pluginDir: path.resolve(pluginDir),
    journalDir: path.resolve(journalDir),
    logDir: path.resolve(logDir),
    maxConcurrentWorkers: Math.max(1, maxConcurrentWorkers),
    heartbeatIntervalMs: Math.max(1000, heartbeatIntervalMs),
    pollIntervalMs: Math.max(500, pollIntervalMs),
  };
}

export function saveAgentConfig(
  config: AgentConfig,
  options: { persistToken?: boolean } = {},
): void {
  fs.mkdirSync(config.homeDir, { recursive: true });
  const configPath = path.join(config.homeDir, "conclave-agent.json");
  fs.writeFileSync(
    configPath,
    JSON.stringify(
      {
        workspaceId: config.workspaceId,
        agentId: config.agentId,
        name: config.name,
        cloudUrl: config.cloudUrl,
        ...(options.persistToken === false
          ? {}
          : { agentToken: config.agentToken }),
        workDir: config.workDir,
        pluginDir: config.pluginDir,
        journalDir: config.journalDir,
        logDir: config.logDir,
        maxConcurrentWorkers: config.maxConcurrentWorkers,
        heartbeatIntervalMs: config.heartbeatIntervalMs,
        pollIntervalMs: config.pollIntervalMs,
      },
      null,
      2,
    ),
    "utf8",
  );
}
