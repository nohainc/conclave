import type { WorkerExecutionContextItem } from "./worker-execution.js";

export interface ConnectorTask {
  readonly taskId: string;
  readonly goalId: string;
  readonly runId: string;
  readonly organizationId: string;
  readonly projectId: string;
  readonly objective: string;
  readonly context: readonly WorkerExecutionContextItem[];
  readonly messages: readonly unknown[];
}

export interface ConnectorSession {
  readonly sessionId: string;
  readonly sessionToken: string;
  readonly organizationId: string;
  readonly projectId: string;
  readonly workerId: string;
  readonly leaseExpiresAt: string;
}

export interface ConnectorSessionRegistration {
  readonly organizationId: string;
  readonly projectId: string;
  readonly workerId: string;
  readonly displayName?: string;
  readonly capabilities: readonly string[];
  readonly leaseMs?: number;
}

export interface ConnectorStatus {
  readonly status: "available" | "busy" | "waiting" | "completed" | "failed";
  readonly detail?: string;
}

export class InteractiveConnectorError extends Error {
  constructor(
    message: string,
    readonly code:
      | "unauthorized"
      | "not_found"
      | "lease_expired"
      | "conflict"
      | "invalid_request",
  ) {
    super(message);
    this.name = "InteractiveConnectorError";
  }
}

interface SessionState extends Omit<ConnectorSession, "leaseExpiresAt"> {
  leaseExpiresAt: string;
  readonly capabilities: readonly string[];
  readonly leaseMs: number;
  taskId: string | null;
}

interface TaskState extends ConnectorTask {
  status: "queued" | "claimed" | "completed" | "released";
  claimedBy: string | null;
  candidates: unknown[];
  result: unknown | null;
  findings: unknown[];
  statusReport: ConnectorStatus | null;
}

export interface InteractiveConnectorOptions {
  readonly registrationToken: string;
  readonly now?: () => number;
  readonly idFactory?: (prefix: string) => string;
}

/**
 * Native-chat connector state machine. A Durable Object or repository-backed
 * service can host the same contract; this class keeps the protocol independent
 * of HTTP, MCP, or a specific web AI.
 */
export class InteractiveConnector {
  private readonly sessions = new Map<string, SessionState>();
  private readonly tasks = new Map<string, TaskState>();
  private readonly now: () => number;
  private readonly idFactory: (prefix: string) => string;

  constructor(private readonly options: InteractiveConnectorOptions) {
    this.now = options.now ?? (() => Date.now());
    this.idFactory =
      options.idFactory ?? ((prefix) => `${prefix}:${crypto.randomUUID()}`);
    if (!options.registrationToken)
      throw new Error("Connector registration token is required");
  }

  registerTask(task: ConnectorTask): void {
    if (this.tasks.has(task.taskId)) {
      throw new InteractiveConnectorError(
        `Task '${task.taskId}' is already registered`,
        "conflict",
      );
    }
    this.tasks.set(task.taskId, {
      ...task,
      status: "queued",
      claimedBy: null,
      candidates: [],
      result: null,
      findings: [],
      statusReport: null,
    });
  }

  getTaskStatus(
    registrationToken: string,
    taskId: string,
  ): {
    readonly status: TaskState["status"];
    readonly result: unknown | null;
    readonly candidates: readonly unknown[];
    readonly findings: readonly unknown[];
    readonly statusReport: ConnectorStatus | null;
  } {
    if (registrationToken !== this.options.registrationToken) {
      throw new InteractiveConnectorError(
        "Connector authentication required",
        "unauthorized",
      );
    }
    const task = this.tasks.get(taskId);
    if (!task)
      throw new InteractiveConnectorError("Task not found", "not_found");
    return {
      status: task.status,
      result: task.result,
      candidates: [...task.candidates],
      findings: [...task.findings],
      statusReport: task.statusReport,
    };
  }

  registerSession(
    token: string,
    registration: ConnectorSessionRegistration,
  ): ConnectorSession {
    if (token !== this.options.registrationToken)
      throw new InteractiveConnectorError(
        "Connector authentication required",
        "unauthorized",
      );
    const leaseMs = registration.leaseMs ?? 5 * 60_000;
    if (!Number.isInteger(leaseMs) || leaseMs < 1_000)
      throw new InteractiveConnectorError(
        "Session lease is invalid",
        "invalid_request",
      );
    const sessionId = this.idFactory("session");
    const session = {
      sessionId,
      sessionToken: this.idFactory("token"),
      organizationId: registration.organizationId,
      projectId: registration.projectId,
      workerId: registration.workerId,
      capabilities: registration.capabilities,
      leaseMs,
      leaseExpiresAt: new Date(this.now() + leaseMs).toISOString(),
      taskId: null,
    } satisfies SessionState;
    this.sessions.set(sessionId, session);
    return this.publicSession(session);
  }

  claimTask(
    sessionId: string,
    sessionToken: string,
    taskId?: string,
  ): ConnectorTask {
    const session = this.authenticate(sessionId, sessionToken);
    if (session.taskId)
      throw new InteractiveConnectorError(
        "Session already has a claimed task",
        "conflict",
      );
    const task = taskId
      ? this.tasks.get(taskId)
      : [...this.tasks.values()].find(
          (candidate) =>
            candidate.status === "queued" &&
            candidate.organizationId === session.organizationId &&
            candidate.projectId === session.projectId,
        );
    if (!task)
      throw new InteractiveConnectorError("Task is not available", "not_found");
    if (task.status !== "queued")
      throw new InteractiveConnectorError(
        "Task is already claimed",
        "conflict",
      );
    if (
      task.organizationId !== session.organizationId ||
      task.projectId !== session.projectId
    ) {
      throw new InteractiveConnectorError(
        "Task is outside the session workspace",
        "unauthorized",
      );
    }
    task.status = "claimed";
    task.claimedBy = session.sessionId;
    session.taskId = task.taskId;
    this.renew(session);
    return task;
  }

  getTask(
    sessionId: string,
    sessionToken: string,
    taskId: string,
  ): ConnectorTask & { readonly status: TaskState["status"] } {
    const session = this.authenticate(sessionId, sessionToken);
    const task = this.authorizedTask(session, taskId);
    return task;
  }

  getContext(
    sessionId: string,
    sessionToken: string,
    taskId: string,
  ): readonly WorkerExecutionContextItem[] {
    const session = this.authenticate(sessionId, sessionToken);
    return this.authorizedTask(session, taskId).context;
  }

  getNextMessage(
    sessionId: string,
    sessionToken: string,
    taskId: string,
  ): unknown | null {
    const session = this.authenticate(sessionId, sessionToken);
    const task = this.authorizedTask(session, taskId);
    return task.messages[0] ?? null;
  }

  submitCandidate(
    sessionId: string,
    sessionToken: string,
    taskId: string,
    candidate: unknown,
  ): void {
    const session = this.authenticate(sessionId, sessionToken);
    this.authorizedTask(session, taskId).candidates.push(candidate);
  }

  submitResult(
    sessionId: string,
    sessionToken: string,
    taskId: string,
    result: unknown,
  ): void {
    const session = this.authenticate(sessionId, sessionToken);
    const task = this.authorizedTask(session, taskId);
    task.result = result;
    task.status = "completed";
    session.taskId = null;
  }

  submitFinding(
    sessionId: string,
    sessionToken: string,
    taskId: string,
    finding: unknown,
  ): void {
    const session = this.authenticate(sessionId, sessionToken);
    this.authorizedTask(session, taskId).findings.push(finding);
  }

  reportStatus(
    sessionId: string,
    sessionToken: string,
    status: ConnectorStatus,
  ): void {
    const session = this.authenticate(sessionId, sessionToken);
    if (session.taskId) this.tasks.get(session.taskId)!.statusReport = status;
  }

  releaseTask(sessionId: string, sessionToken: string, taskId: string): void {
    const session = this.authenticate(sessionId, sessionToken);
    const task = this.authorizedTask(session, taskId);
    task.status = "released";
    task.claimedBy = null;
    session.taskId = null;
  }

  private authenticate(sessionId: string, sessionToken: string): SessionState {
    const session = this.sessions.get(sessionId);
    if (!session || session.sessionToken !== sessionToken)
      throw new InteractiveConnectorError(
        "Invalid connector session",
        "unauthorized",
      );
    if (this.now() >= Date.parse(session.leaseExpiresAt)) {
      this.sessions.delete(sessionId);
      throw new InteractiveConnectorError(
        "Connector session lease expired",
        "lease_expired",
      );
    }
    this.renew(session);
    return session;
  }

  private renew(session: SessionState): void {
    session.leaseExpiresAt = new Date(
      this.now() + session.leaseMs,
    ).toISOString();
  }

  private authorizedTask(session: SessionState, taskId: string): TaskState {
    const task = this.tasks.get(taskId);
    if (!task)
      throw new InteractiveConnectorError("Task not found", "not_found");
    if (task.claimedBy !== session.sessionId)
      throw new InteractiveConnectorError(
        "Task is not claimed by this session",
        "unauthorized",
      );
    if (
      task.organizationId !== session.organizationId ||
      task.projectId !== session.projectId
    ) {
      throw new InteractiveConnectorError(
        "Task is outside the session workspace",
        "unauthorized",
      );
    }
    return task;
  }

  private publicSession(session: SessionState): ConnectorSession {
    return {
      sessionId: session.sessionId,
      sessionToken: session.sessionToken,
      organizationId: session.organizationId,
      projectId: session.projectId,
      workerId: session.workerId,
      leaseExpiresAt: session.leaseExpiresAt,
    };
  }
}
