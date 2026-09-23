import type { AssignmentContextItem } from "./assignment-execution.js";
import {
  createWorkerSessionNamespace,
  type SessionMode,
  type WorkerSessionNamespace,
} from "./session-isolation.js";

export interface ConnectorAssignment {
  readonly assignmentId: string;
  readonly attemptId: string;
  readonly taskId: string;
  readonly goalId: string;
  readonly runId: string;
  readonly organizationId: string;
  readonly projectId: string;
  readonly hostId: string;
  readonly workerId: string;
  readonly credentialProfileId: string;
  readonly requestedByUserId?: string;
  readonly sessionMode?: SessionMode;
  readonly objective: string;
  readonly context: readonly AssignmentContextItem[];
  readonly messages: readonly unknown[];
}

export type ConnectorAssignmentRegistration = Omit<
  ConnectorAssignment,
  "assignmentId" | "attemptId" | "hostId" | "workerId" | "credentialProfileId"
> & {
  readonly assignmentId?: string;
  readonly attemptId?: string;
  readonly hostId?: string;
  readonly workerId?: string;
  readonly credentialProfileId?: string;
};

export interface ConnectorSession {
  readonly sessionId: string;
  readonly sessionToken: string;
  readonly organizationId: string;
  readonly projectId: string;
  readonly workerId: string;
  readonly credentialProfileId: string;
  readonly requestedByUserId?: string;
  readonly sessionMode: SessionMode;
  readonly namespace: string;
  readonly leaseExpiresAt: string;
}

export interface ConnectorSessionRegistration {
  readonly organizationId: string;
  readonly projectId: string;
  readonly workerId: string;
  readonly credentialProfileId: string;
  readonly requestedByUserId?: string;
  readonly sessionMode?: SessionMode;
  readonly displayName?: string;
  readonly capabilities: readonly string[];
  readonly leaseMs?: number;
  readonly quotaRemaining?: number;
}

export interface ConnectorStatus {
  readonly status:
    | "available"
    | "busy"
    | "waiting"
    | "waiting_for_user"
    | "quota_exceeded"
    | "reconnecting"
    | "completed"
    | "failed";
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
  readonly quotaRemaining?: number;
  assignmentId: string | null;
  readonly namespaceInput: WorkerSessionNamespace;
}

interface AssignmentState extends ConnectorAssignment {
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
 * Assignment mailbox and session lease relay for web AI Workers.
 * It does not execute work or create Core state; Cloud remains authoritative
 * for the WorkerAssignment and the Web AI Worker reports the result here.
 */
export class InteractiveConnector {
  private readonly sessions = new Map<string, SessionState>();
  private readonly assignments = new Map<string, AssignmentState>();
  private readonly now: () => number;
  private readonly idFactory: (prefix: string) => string;

  constructor(private readonly options: InteractiveConnectorOptions) {
    this.now = options.now ?? (() => Date.now());
    this.idFactory =
      options.idFactory ?? ((prefix) => `${prefix}:${crypto.randomUUID()}`);
    if (!options.registrationToken)
      throw new Error("Connector authentication is required");
  }

  registerAssignment(input: ConnectorAssignmentRegistration): void {
    if (this.assignments.has(input.taskId)) {
      throw new InteractiveConnectorError(
        `Assignment '${input.taskId}' is already registered`,
        "conflict",
      );
    }
    this.assignments.set(input.taskId, {
      ...input,
      assignmentId: input.assignmentId ?? `assignment:${input.taskId}`,
      attemptId: input.attemptId ?? `attempt:${input.taskId}`,
      hostId: input.hostId ?? "web-host",
      workerId: input.workerId ?? "web-worker",
      credentialProfileId: input.credentialProfileId ?? "web-profile",
      status: "queued",
      claimedBy: null,
      candidates: [],
      result: null,
      findings: [],
      statusReport: null,
    });
  }

  getAssignmentStatus(registrationToken: string, taskId: string) {
    this.requireRegistrationToken(registrationToken);
    const assignment = this.assignments.get(taskId);
    if (!assignment)
      throw new InteractiveConnectorError("Assignment not found", "not_found");
    return {
      assignmentId: assignment.assignmentId,
      attemptId: assignment.attemptId,
      status: assignment.status,
      result: assignment.result,
      candidates: [...assignment.candidates],
      findings: [...assignment.findings],
      statusReport: assignment.statusReport,
    };
  }

  registerSession(
    token: string,
    registration: ConnectorSessionRegistration,
  ): ConnectorSession {
    this.requireRegistrationToken(token);
    if (!registration.credentialProfileId?.trim()) {
      throw new InteractiveConnectorError(
        "Credential Profile is required for a web Worker session",
        "invalid_request",
      );
    }
    if (
      registration.quotaRemaining !== undefined &&
      (!Number.isInteger(registration.quotaRemaining) ||
        registration.quotaRemaining < 0)
    ) {
      throw new InteractiveConnectorError(
        "Credential Profile quota is invalid",
        "invalid_request",
      );
    }
    const leaseMs = registration.leaseMs ?? 5 * 60_000;
    if (!Number.isInteger(leaseMs) || leaseMs < 1_000)
      throw new InteractiveConnectorError(
        "Session lease is invalid",
        "invalid_request",
      );
    const sessionMode = registration.sessionMode ?? "fresh";
    if (!["fresh", "task", "chat", "project"].includes(sessionMode)) {
      throw new InteractiveConnectorError(
        "Session mode is invalid",
        "invalid_request",
      );
    }
    const sessionId = this.idFactory("session");
    const namespaceInput: WorkerSessionNamespace = {
      workerId: registration.workerId,
      credentialProfileId: registration.credentialProfileId,
      projectId: registration.projectId,
      sessionId,
      mode: sessionMode,
    };
    const session = {
      sessionId,
      sessionToken: this.idFactory("token"),
      organizationId: registration.organizationId,
      projectId: registration.projectId,
      workerId: registration.workerId,
      credentialProfileId: registration.credentialProfileId,
      capabilities: registration.capabilities,
      leaseMs,
      quotaRemaining: registration.quotaRemaining,
      requestedByUserId: registration.requestedByUserId,
      sessionMode,
      namespace: createWorkerSessionNamespace(namespaceInput),
      namespaceInput,
      leaseExpiresAt: new Date(this.now() + leaseMs).toISOString(),
      assignmentId: null,
    } satisfies SessionState;
    this.sessions.set(session.sessionId, session);
    return this.publicSession(session);
  }

  claimAssignment(
    sessionId: string,
    sessionToken: string,
    taskId?: string,
  ): ConnectorAssignment {
    const session = this.authenticate(sessionId, sessionToken);
    if (session.assignmentId)
      throw new InteractiveConnectorError(
        "Session already has an assignment",
        "conflict",
      );
    const assignment = taskId
      ? this.assignments.get(taskId)
      : [...this.assignments.values()].find(
          (candidate) =>
            candidate.status === "queued" &&
            candidate.organizationId === session.organizationId &&
            candidate.projectId === session.projectId,
        );
    if (!assignment)
      throw new InteractiveConnectorError(
        "Assignment is not available",
        "not_found",
      );
    if (assignment.status !== "queued")
      throw new InteractiveConnectorError(
        "Assignment is already claimed",
        "conflict",
      );
    this.authorizeAssignment(session, assignment);
    if (session.quotaRemaining !== undefined && session.quotaRemaining <= 0) {
      assignment.statusReport = { status: "quota_exceeded" };
      throw new InteractiveConnectorError(
        "Credential Profile quota is exhausted",
        "conflict",
      );
    }
    assignment.status = "claimed";
    assignment.claimedBy = session.sessionId;
    session.assignmentId = assignment.assignmentId;
    this.renew(session);
    return assignment;
  }

  getAssignment(sessionId: string, sessionToken: string, taskId: string) {
    const session = this.authenticate(sessionId, sessionToken);
    return this.authorizedAssignment(session, taskId);
  }

  getContext(sessionId: string, sessionToken: string, taskId: string) {
    const session = this.authenticate(sessionId, sessionToken);
    return this.authorizedAssignment(session, taskId).context;
  }

  getNextMessage(sessionId: string, sessionToken: string, taskId: string) {
    const session = this.authenticate(sessionId, sessionToken);
    return this.authorizedAssignment(session, taskId).messages[0] ?? null;
  }

  submitCandidate(
    sessionId: string,
    sessionToken: string,
    taskId: string,
    candidate: unknown,
  ): void {
    const session = this.authenticate(sessionId, sessionToken);
    this.authorizedAssignment(session, taskId).candidates.push(candidate);
  }

  submitResult(
    sessionId: string,
    sessionToken: string,
    taskId: string,
    result: unknown,
  ): void {
    const session = this.authenticate(sessionId, sessionToken);
    const assignment = this.authorizedAssignment(session, taskId);
    if (!this.matchesAssignment(assignment, result))
      throw new InteractiveConnectorError(
        "WorkerAssignmentResult does not match the claimed assignment",
        "invalid_request",
      );
    assignment.result = result;
    assignment.status = "completed";
    session.assignmentId = null;
  }

  submitFinding(
    sessionId: string,
    sessionToken: string,
    taskId: string,
    finding: unknown,
  ): void {
    const session = this.authenticate(sessionId, sessionToken);
    this.authorizedAssignment(session, taskId).findings.push(finding);
  }

  reportStatus(
    sessionId: string,
    sessionToken: string,
    status: ConnectorStatus,
  ): void {
    const session = this.authenticate(sessionId, sessionToken);
    if (session.assignmentId) {
      const assignment = [...this.assignments.values()].find(
        (item) => item.assignmentId === session.assignmentId,
      );
      if (assignment) assignment.statusReport = status;
    }
  }

  releaseAssignment(
    sessionId: string,
    sessionToken: string,
    taskId: string,
  ): void {
    const session = this.authenticate(sessionId, sessionToken);
    const assignment = this.authorizedAssignment(session, taskId);
    assignment.status = "released";
    assignment.claimedBy = null;
    session.assignmentId = null;
  }

  private requireRegistrationToken(token: string): void {
    if (token !== this.options.registrationToken)
      throw new InteractiveConnectorError(
        "Connector authentication required",
        "unauthorized",
      );
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

  private authorizedAssignment(
    session: SessionState,
    taskId: string,
  ): AssignmentState {
    const assignment = this.assignments.get(taskId);
    if (!assignment)
      throw new InteractiveConnectorError("Assignment not found", "not_found");
    if (assignment.claimedBy !== session.sessionId)
      throw new InteractiveConnectorError(
        "Assignment is not claimed by this session",
        "unauthorized",
      );
    this.authorizeAssignment(session, assignment);
    return assignment;
  }

  private authorizeAssignment(
    session: SessionState,
    assignment: AssignmentState,
  ): void {
    if (
      assignment.organizationId !== session.organizationId ||
      assignment.projectId !== session.projectId
    ) {
      throw new InteractiveConnectorError(
        "Assignment is outside the session workspace",
        "unauthorized",
      );
    }
    if (assignment.credentialProfileId !== session.credentialProfileId) {
      throw new InteractiveConnectorError(
        "Assignment credential Profile is not available to this session",
        "unauthorized",
      );
    }
    if (
      assignment.requestedByUserId !== undefined &&
      assignment.requestedByUserId !== session.requestedByUserId
    ) {
      throw new InteractiveConnectorError(
        "Assignment belongs to another Conclave user session",
        "unauthorized",
      );
    }
    const assignmentMode = assignment.sessionMode ?? "fresh";
    if (assignmentMode !== session.sessionMode) {
      throw new InteractiveConnectorError(
        "Assignment session mode is not available to this session",
        "unauthorized",
      );
    }
  }

  private matchesAssignment(
    assignment: AssignmentState,
    result: unknown,
  ): boolean {
    if (typeof result !== "object" || result === null) return false;
    const value = result as Record<string, unknown>;
    return (
      value.assignmentId === assignment.assignmentId &&
      value.attemptId === assignment.attemptId &&
      value.runId === assignment.runId &&
      value.taskId === assignment.taskId &&
      value.workerId === assignment.workerId &&
      value.hostId === assignment.hostId &&
      value.credentialProfileId === assignment.credentialProfileId &&
      typeof value.status === "string" &&
      ["completed", "failed", "cancelled"].includes(value.status)
    );
  }

  private publicSession(session: SessionState): ConnectorSession {
    return {
      sessionId: session.sessionId,
      sessionToken: session.sessionToken,
      organizationId: session.organizationId,
      projectId: session.projectId,
      workerId: session.workerId,
      credentialProfileId: session.credentialProfileId,
      requestedByUserId: session.requestedByUserId,
      sessionMode: session.sessionMode,
      namespace: session.namespace,
      leaseExpiresAt: session.leaseExpiresAt,
    };
  }
}
