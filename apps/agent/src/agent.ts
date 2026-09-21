import os from "node:os";
import {
  AGENT_PROTOCOL_NAME,
  AGENT_PROTOCOL_VERSION,
  reconcileAssignmentJournal,
  type AgentProtocolMessage,
  type AgentCapabilities,
  type AgentJournalEntry,
  type AssignmentStartPayload,
} from "@conclave/agent-protocol";
import { loadAgentConfig, type AgentConfig } from "./config.js";
import { AgentStorage } from "./storage.js";
import { AgentLogger } from "./logger.js";
import { detectAgentCapabilities } from "./capabilities.js";
import { AgentJournal } from "./journal.js";
import { WorkerManager } from "./worker-manager.js";
import { PluginManager } from "./plugin-manager.js";
import { CloudClient, type CloudTransport } from "./cloud-client.js";
import {
  AgentUpdater,
  type AgentReleaseInfo,
  type SelfUpdateResult,
  type UpdatePhase,
} from "./updater.js";

export class ConclaveAgentHost {
  readonly config: AgentConfig;
  readonly storage: AgentStorage;
  readonly logger: AgentLogger;
  readonly journal: AgentJournal;
  readonly workerManager: WorkerManager;
  readonly pluginManager: PluginManager;
  readonly cloudClient: CloudClient;
  readonly updater: AgentUpdater;

  private capabilities: AgentCapabilities;
  private sessionId?: string;
  private heartbeatTimer?: NodeJS.Timeout;
  private isRunning = false;

  constructor(options?: {
    config?: Partial<AgentConfig>;
    transport?: CloudTransport;
    signingKey?: string;
  }) {
    this.config = loadAgentConfig(options?.config);
    this.logger = new AgentLogger(this.config.logDir);
    this.storage = new AgentStorage(this.config);
    this.journal = new AgentJournal(this.config);
    this.workerManager = new WorkerManager(
      this.config,
      this.storage,
      this.logger,
    );
    this.pluginManager = new PluginManager(
      this.config,
      this.storage,
      this.logger,
      this.workerManager,
      options?.signingKey,
    );
    this.workerManager.setPluginManager(this.pluginManager);
    this.cloudClient = new CloudClient(
      this.config,
      this.logger,
      options?.transport,
    );
    this.updater = new AgentUpdater(
      this.config,
      this.logger,
      this.workerManager,
      options?.signingKey,
    );
    this.capabilities = detectAgentCapabilities(this.config);
  }

  get isOnline(): boolean {
    return this.isRunning && !!this.sessionId;
  }

  get currentSessionId(): string | undefined {
    return this.sessionId;
  }

  /**
   * Starts the Conclave Agent host.
   */
  async start(): Promise<void> {
    if (this.isRunning) {
      return;
    }

    this.logger.info("Starting Conclave Agent Host", {
      agentId: this.config.agentId,
      workspaceId: this.config.workspaceId,
      cloudUrl: this.config.cloudUrl,
    });

    // 1. Ensure local storage directories
    this.storage.ensureDirectories();

    // 2. Load journal
    this.journal.load();

    // 3. Connect & Handshake with Cloud
    const helloAck = await this.cloudClient.sendHello({
      agentId: this.config.agentId,
      workspaceId: this.config.workspaceId,
      name: this.config.name,
      hostname: os.hostname(),
      agentVersion: this.capabilities.agentVersion,
      capabilities: this.capabilities,
    });

    this.sessionId = helloAck.sessionId;
    this.isRunning = true;

    this.logger.info("Connected to Conclave Cloud", {
      sessionId: this.sessionId,
      serverVersion: helloAck.serverVersion,
      heartbeatIntervalMs: helloAck.heartbeatIntervalMs,
    });

    // 4. Start heartbeat loop
    const intervalMs =
      helloAck.heartbeatIntervalMs || this.config.heartbeatIntervalMs;
    this.startHeartbeatLoop(intervalMs);

    // 5. Reconcile assignment journal with Cloud
    await this.reconcileJournal();
  }

  /**
   * Stops the agent host gracefully.
   */
  async stop(): Promise<void> {
    if (!this.isRunning) {
      return;
    }

    this.logger.info("Stopping Conclave Agent Host", {
      agentId: this.config.agentId,
      sessionId: this.sessionId,
    });

    this.isRunning = false;
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = undefined;
    }

    // Send final offline/draining heartbeat if session exists
    if (this.sessionId) {
      try {
        await this.cloudClient.sendHeartbeat({
          agentId: this.config.agentId,
          workspaceId: this.config.workspaceId,
          sessionId: this.sessionId,
          status: "draining",
          activeWorkers: this.workerManager.listWorkers().length,
          activeAssignments: this.workerManager.getActiveAssignmentsCount(),
        });
      } catch {
        // ignore error during shutdown
      }
    }

    this.sessionId = undefined;
    this.logger.info("Conclave Agent Host stopped cleanly");
  }

  /**
   * Starts periodic heartbeat timer.
   */
  private startHeartbeatLoop(intervalMs: number): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
    }

    this.heartbeatTimer = setInterval(async () => {
      if (!this.isRunning || !this.sessionId) return;

      try {
        const freeMem = os.freemem();
        const activeCount = this.workerManager.getActiveAssignmentsCount();
        const status =
          activeCount >= this.config.maxConcurrentWorkers ? "busy" : "online";

        await this.cloudClient.sendHeartbeat({
          agentId: this.config.agentId,
          workspaceId: this.config.workspaceId,
          sessionId: this.sessionId,
          status,
          activeWorkers: this.workerManager.listWorkers().length,
          activeAssignments: activeCount,
          memoryFreeBytes: freeMem,
        });
      } catch (err) {
        this.logger.error("Failed to send heartbeat", {
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }, intervalMs);

    if (typeof this.heartbeatTimer.unref === "function") {
      this.heartbeatTimer.unref();
    }
  }

  /**
   * Reconciles assignment journal with Cloud state.
   */
  async reconcileJournal(): Promise<void> {
    try {
      const syncResponse = await this.cloudClient.sendSync({
        agentId: this.config.agentId,
        workspaceId: this.config.workspaceId,
        installedPluginVersions: {},
        activeWorkerIds: this.workerManager
          .listWorkers()
          .map((w) => w.workerId),
        unreconciledAssignmentIds: this.journal
          .getUnreconciled()
          .map((j) => j.assignmentId),
      });

      // Synchronize desired workers
      for (const desiredWorker of syncResponse.desiredWorkers) {
        this.workerManager.configureWorker(desiredWorker);
      }

      // Convert cloud active assignment IDs for journal reconciliation
      const cloudRecords = syncResponse.activeAssignmentIds.map((id) => ({
        assignmentId: id,
        attemptId: id,
        idempotencyKey: id,
        status: "running",
      }));

      const actions = reconcileAssignmentJournal(
        cloudRecords,
        this.journal.list(),
      );

      for (const item of actions) {
        if (item.action === "submit_result") {
          const entry = this.journal.get(item.assignmentId);
          if (entry) {
            await this.deliverTerminalResult(entry);
          }
        } else if (
          item.action === "cancel_orphaned" ||
          item.action === "acknowledge_synced"
        ) {
          this.journal.acknowledge(item.assignmentId);
        }
      }
    } catch (err) {
      this.logger.error("Journal reconciliation failed", {
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }

  /**
   * Dispatches and delivers terminal assignment result to Cloud.
   */
  private async deliverTerminalResult(entry: AgentJournalEntry): Promise<void> {
    const isCompleted = entry.status === "completed";
    const baseEnvelope = {
      protocol: AGENT_PROTOCOL_NAME,
      protocolVersion: AGENT_PROTOCOL_VERSION,
      messageId: `msg-${Date.now()}-${Math.random().toString(36).slice(2, 9)}`,
      timestamp: new Date().toISOString(),
      workspaceId: this.config.workspaceId,
      agentId: this.config.agentId,
      workerId: (entry.terminalResult?.workerId as string) || "worker-default",
      runId: (entry.terminalResult?.runId as string) || "run-default",
      taskId: (entry.terminalResult?.taskId as string) || "task-default",
      attemptId: entry.attemptId,
      assignmentId: entry.assignmentId,
      idempotencyKey: entry.idempotencyKey,
    };

    if (isCompleted) {
      const msg: AgentProtocolMessage = {
        ...baseEnvelope,
        type: "assignment.result",
        payload: {
          status: "completed",
          summary:
            (entry.terminalResult?.summary as string) ||
            "Assignment completed successfully",
          output:
            (entry.terminalResult?.output as Record<string, unknown>) ?? null,
          artifactIds: (entry.terminalResult?.artifactIds as string[]) ?? [],
        },
      };
      await this.cloudClient.sendMessage(msg);
      this.journal.acknowledge(entry.assignmentId);
    } else {
      const msg: AgentProtocolMessage = {
        ...baseEnvelope,
        type: "assignment.error",
        payload: {
          status: "failed",
          error: {
            code:
              (entry.terminalResult?.errorCode as string) || "EXECUTION_FAILED",
            message:
              (entry.terminalResult?.errorMessage as string) ||
              "Assignment execution failed",
            retryable: false,
          },
        },
      };
      await this.cloudClient.sendMessage(msg);
      this.journal.acknowledge(entry.assignmentId);
    }
  }

  /**
   * Processes incoming Agent Protocol messages received from Cloud.
   */
  async handleIncomingMessage(
    message: AgentProtocolMessage,
  ): Promise<AgentProtocolMessage | void> {
    switch (message.type) {
      case "agent.update.available": {
        const payload = message.payload;
        void this.drainAndUpgrade({
          version: payload.version,
          channel: payload.channel,
          packageDigest: payload.packageDigest,
          packageR2Key: payload.packageR2Key,
          signature: payload.signature,
          releaseNotes: payload.releaseNotes,
          supportedOS: ["macos", "linux", "windows"],
          supportedArch: ["arm64", "x64"],
        });
        return undefined;
      }

      case "worker.configure": {
        this.workerManager.configureWorker(message.payload.worker);
        const status = this.workerManager.getWorkerStatus(
          message.payload.worker.workerId,
        );
        if (status) {
          return {
            protocol: AGENT_PROTOCOL_NAME,
            protocolVersion: AGENT_PROTOCOL_VERSION,
            messageId: `msg-${Date.now()}`,
            timestamp: new Date().toISOString(),
            type: "worker.status",
            payload: status,
          };
        }
        return undefined;
      }

      case "assignment.start": {
        const {
          workspaceId,
          agentId,
          workerId,
          runId,
          taskId,
          attemptId,
          assignmentId,
          idempotencyKey,
        } = message;

        // Check worker and capacity
        const worker = this.workerManager.getWorker(workerId);
        if (!worker || !worker.enabled) {
          return {
            protocol: AGENT_PROTOCOL_NAME,
            protocolVersion: AGENT_PROTOCOL_VERSION,
            messageId: `msg-${Date.now()}`,
            correlationId: message.messageId,
            timestamp: new Date().toISOString(),
            workspaceId,
            agentId,
            workerId,
            runId,
            taskId,
            attemptId,
            assignmentId,
            idempotencyKey,
            type: "assignment.ack",
            payload: {
              accepted: false,
              reason: worker
                ? `Worker '${workerId}' is disabled`
                : `Worker '${workerId}' not found`,
            },
          };
        }

        // Acknowledge acceptance
        const ackMessage: AgentProtocolMessage = {
          protocol: AGENT_PROTOCOL_NAME,
          protocolVersion: AGENT_PROTOCOL_VERSION,
          messageId: `msg-${Date.now()}`,
          correlationId: message.messageId,
          timestamp: new Date().toISOString(),
          workspaceId,
          agentId,
          workerId,
          runId,
          taskId,
          attemptId,
          assignmentId,
          idempotencyKey,
          type: "assignment.ack",
          payload: {
            accepted: true,
            estimatedStartMs: 0,
          },
        };

        // Record start in journal
        this.journal.recordStart(assignmentId, attemptId, idempotencyKey);

        // Execute asynchronously
        void this.executeAndReportAssignment({
          workspaceId,
          agentId,
          workerId,
          runId,
          taskId,
          attemptId,
          assignmentId,
          idempotencyKey,
          payload: message.payload,
        });

        return ackMessage;
      }

      case "assignment.cancel": {
        const {
          workspaceId,
          agentId,
          workerId,
          runId,
          taskId,
          attemptId,
          assignmentId,
          idempotencyKey,
        } = message;
        const cancelled = this.workerManager.cancelAssignment(
          assignmentId,
          message.payload.reason,
        );

        return {
          protocol: AGENT_PROTOCOL_NAME,
          protocolVersion: AGENT_PROTOCOL_VERSION,
          messageId: `msg-${Date.now()}`,
          correlationId: message.messageId,
          timestamp: new Date().toISOString(),
          workspaceId,
          agentId,
          workerId,
          runId,
          taskId,
          attemptId,
          assignmentId,
          idempotencyKey,
          type: "assignment.cancel.ack",
          payload: {
            cancelled,
            alreadyTerminated: !cancelled,
          },
        };
      }

      default:
        return undefined;
    }
  }

  /**
   * Helper that executes the assignment, streams progress, and submits result to Cloud.
   */
  private async executeAndReportAssignment(input: {
    workspaceId: string;
    agentId: string;
    workerId: string;
    runId: string;
    taskId: string;
    attemptId: string;
    assignmentId: string;
    idempotencyKey: string;
    payload: AssignmentStartPayload;
  }): Promise<void> {
    const {
      workspaceId,
      agentId,
      workerId,
      runId,
      taskId,
      attemptId,
      assignmentId,
      idempotencyKey,
      payload,
    } = input;

    const baseEnv = {
      protocol: AGENT_PROTOCOL_NAME,
      protocolVersion: AGENT_PROTOCOL_VERSION,
      messageId: `msg-${Date.now()}`,
      timestamp: new Date().toISOString(),
      workspaceId,
      agentId,
      workerId,
      runId,
      taskId,
      attemptId,
      assignmentId,
      idempotencyKey,
    };

    const execution = await this.workerManager.executeAssignment({
      assignmentId,
      workerId,
      runId,
      taskId,
      attemptId,
      idempotencyKey,
      payload,
      onProgress: (stage, percentComplete, logChunk) => {
        void this.cloudClient.sendMessage({
          ...baseEnv,
          messageId: `msg-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
          timestamp: new Date().toISOString(),
          type: "assignment.progress",
          payload: {
            stage,
            percentComplete,
            logChunk,
          },
        });
      },
    });

    if (execution.success) {
      this.journal.recordResult(
        assignmentId,
        execution.result as unknown as Record<string, unknown>,
        "completed",
      );
      await this.cloudClient.sendMessage({
        ...baseEnv,
        messageId: `msg-${Date.now()}`,
        timestamp: new Date().toISOString(),
        type: "assignment.result",
        payload: execution.result,
      });
      this.journal.acknowledge(assignmentId);
    } else {
      this.journal.recordResult(
        assignmentId,
        {
          errorCode: execution.failure.error.code,
          errorMessage: execution.failure.error.message,
        },
        "failed",
      );
      await this.cloudClient.sendMessage({
        ...baseEnv,
        messageId: `msg-${Date.now()}`,
        timestamp: new Date().toISOString(),
        type: "assignment.error",
        payload: execution.failure,
      });
      this.journal.acknowledge(assignmentId);
    }
  }

  /**
   * Performs an agent self-update by draining in-flight assignments, staging, cutover, health check, and rollback on failure.
   */
  async drainAndUpgrade(
    release: AgentReleaseInfo,
    customHealthCheck?: () => Promise<boolean>,
  ): Promise<SelfUpdateResult> {
    const currentVersion = this.capabilities.agentVersion;

    const reportStatus = (phase: UpdatePhase, error?: string) => {
      if (this.sessionId) {
        const statusMsg: AgentProtocolMessage = {
          protocol: AGENT_PROTOCOL_NAME,
          protocolVersion: AGENT_PROTOCOL_VERSION,
          messageId: `msg-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
          timestamp: new Date().toISOString(),
          type: "agent.update.status",
          payload: {
            fromVersion: currentVersion,
            targetVersion: release.version,
            status: phase,
            error,
          },
        };
        void this.cloudClient.sendMessage(statusMsg);
      }
    };

    return await this.updater.performSelfUpdate({
      currentVersion,
      channel: release.channel,
      customHealthCheck,
      onPhaseChange: (phase, details) => {
        this.logger.info(`Agent update phase: ${phase}`, { details });
        reportStatus(phase, phase === "failed" ? details : undefined);
      },
    });
  }
}
