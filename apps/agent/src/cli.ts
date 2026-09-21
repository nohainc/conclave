#!/usr/bin/env node
import { loadAgentConfig, saveAgentConfig } from "./config.js";
import { ConclaveAgentHost } from "./agent.js";
import { CloudClient } from "./cloud-client.js";
import { AgentLogger } from "./logger.js";
import { AgentUpdater, type UpdatePhase } from "./updater.js";
import { createCredentialStore } from "./credentials.js";
import { installMacOSAgent, uninstallMacOSAgent } from "./installer.js";
import { MacOSLaunchAgentService } from "./service-manager.js";

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const command = args[0] || "start";

  if (command === "enroll") {
    const tokenIdx = args.indexOf("--token");
    const serverIdx = args.indexOf("--server");
    const token =
      tokenIdx !== -1
        ? args[tokenIdx + 1]
        : process.env.CONCLAVE_ENROLLMENT_TOKEN;
    const server =
      serverIdx !== -1 ? args[serverIdx + 1] : process.env.CONCLAVE_CLOUD_URL;

    if (!token) {
      console.error("Error: --token <token> is required for enrollment");
      process.exit(1);
    }

    const config = loadAgentConfig({ cloudUrl: server });
    const logger = new AgentLogger(config.logDir);
    const client = new CloudClient(config, logger);

    try {
      console.log(`Enrolling with Conclave Cloud at ${config.cloudUrl}...`);
      const result = await client.enroll(token);
      const updatedConfig = {
        ...config,
        agentId: result.agentId,
        workspaceId: result.workspaceId,
        agentToken: result.authToken,
      };
      if (process.platform === "darwin") {
        await createCredentialStore().set(result.agentId, result.authToken);
      }
      saveAgentConfig(updatedConfig, {
        persistToken: process.platform !== "darwin",
      });
      console.log("Enrollment successful!");
      console.log(`Agent ID: ${result.agentId}`);
      console.log(`Workspace ID: ${result.workspaceId}`);
      console.log(
        `Configuration saved to ${config.homeDir}/conclave-agent.json`,
      );
    } catch (err) {
      console.error(
        "Enrollment failed:",
        err instanceof Error ? err.message : String(err),
      );
      process.exit(1);
    }
    return;
  }

  if (command === "install") {
    const config = loadAgentConfig();
    const executable =
      args[args.indexOf("--executable") + 1] ||
      process.argv[1] ||
      process.execPath;
    try {
      await installMacOSAgent(config, executable);
      console.log("Conclave Agent background service installed.");
    } catch (err) {
      console.error(err instanceof Error ? err.message : String(err));
      process.exit(1);
    }
    return;
  }

  if (command === "uninstall") {
    try {
      await uninstallMacOSAgent();
      console.log(
        "Conclave Agent background service uninstalled. Local data was preserved.",
      );
    } catch (err) {
      console.error(err instanceof Error ? err.message : String(err));
      process.exit(1);
    }
    return;
  }

  if (command === "service" && args[1] === "status") {
    try {
      console.log(await new MacOSLaunchAgentService().status());
    } catch (err) {
      console.error(err instanceof Error ? err.message : String(err));
      process.exit(1);
    }
    return;
  }

  if (command === "status") {
    const config = loadAgentConfig();
    console.log("Conclave Agent Configuration:");
    console.log(`  Agent ID:       ${config.agentId}`);
    console.log(`  Workspace ID:   ${config.workspaceId}`);
    console.log(`  Cloud URL:      ${config.cloudUrl}`);
    console.log(`  Home Directory: ${config.homeDir}`);
    console.log(`  Work Directory: ${config.workDir}`);
    console.log(
      `  Enrolled:       ${config.agentToken ? "Yes (Token configured)" : "No"}`,
    );
    return;
  }

  if (args.includes("--health-check") || command === "health-check") {
    console.log("Conclave Agent Health Check: OK");
    process.exit(0);
  }

  if (command === "update") {
    const config = loadAgentConfig();
    const logger = new AgentLogger(config.logDir);
    const updater = new AgentUpdater(config, logger);
    const channelIdx = args.indexOf("--channel");
    const channel =
      channelIdx !== -1 &&
      (args[channelIdx + 1] === "beta" ||
        args[channelIdx + 1] === "development")
        ? (args[channelIdx + 1] as "beta" | "development")
        : "stable";

    console.log(
      `Checking for Conclave Agent updates on channel '${channel}'...`,
    );
    const result = await updater.performSelfUpdate({
      currentVersion: "2.0.0",
      channel,
      onPhaseChange: (phase: UpdatePhase, details?: string) => {
        console.log(`[Update] ${phase}${details ? `: ${details}` : ""}`);
      },
    });

    if (result.success) {
      console.log(
        `Successfully updated agent to version ${result.targetVersion}!`,
      );
      process.exit(0);
    } else {
      console.error(`Update failed: ${result.error}`);
      process.exit(1);
    }
    return;
  }

  if (command === "start") {
    const config = loadAgentConfig();
    const agent = new ConclaveAgentHost({ config });

    const handleShutdown = async (signal: string) => {
      console.log(
        `\nReceived ${signal}, shutting down Conclave Agent gracefully...`,
      );
      await agent.stop();
      process.exit(0);
    };

    process.on("SIGINT", () => void handleShutdown("SIGINT"));
    process.on("SIGTERM", () => void handleShutdown("SIGTERM"));

    console.log(
      `Starting Conclave Agent '${config.name}' (${config.agentId})...`,
    );
    try {
      await agent.start();
      console.log(
        `Conclave Agent is online. Session: ${agent.currentSessionId}`,
      );
    } catch (err) {
      console.error(
        "Failed to start Conclave Agent:",
        err instanceof Error ? err.message : String(err),
      );
      process.exit(1);
    }
    return;
  }

  console.log(`
Usage: conclave-agent <command> [options]

Commands:
  start                     Start the Conclave Agent host daemon
  enroll --token <token>    Enroll this agent with Conclave Cloud
  install [--executable <path>] Install the macOS background service
  uninstall                 Remove the macOS background service (preserves data)
  service status            Show macOS background service status
  status                    Display current agent configuration and status
  update [--channel <ch>]   Check and perform agent self-update (stable/beta/development)
  --health-check            Run binary health check and self-test
`);
}

void main();
