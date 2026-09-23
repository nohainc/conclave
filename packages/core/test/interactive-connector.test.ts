import { describe, expect, it } from "vitest";

import {
  InteractiveConnector,
  InteractiveConnectorError,
} from "../src/index.js";

describe("interactive connector", () => {
  it("registers, leases, claims, exchanges, and releases a native-chat task", () => {
    let now = 1_000_000;
    const connector = new InteractiveConnector({
      registrationToken: "register-secret",
      now: () => now,
      idFactory: (prefix) => `${prefix}-1`,
    });
    connector.registerAssignment({
      taskId: "task-1",
      goalId: "goal-1",
      runId: "run-1",
      organizationId: "org-1",
      projectId: "project-1",
      credentialProfileId: "profile-1",
      objective: "Review the proposal",
      context: [],
      messages: [{ type: "review", text: "Inspect the candidate" }],
    });
    const session = connector.registerSession("register-secret", {
      organizationId: "org-1",
      projectId: "project-1",
      workerId: "web-reviewer",
      credentialProfileId: "profile-1",
      capabilities: ["code_review"],
      leaseMs: 10_000,
    });
    const assignment = connector.claimAssignment(
      session.sessionId,
      session.sessionToken,
    );
    expect(assignment.taskId).toBe("task-1");
    expect(
      connector.getNextMessage(
        session.sessionId,
        session.sessionToken,
        "task-1",
      ),
    ).toEqual({
      type: "review",
      text: "Inspect the candidate",
    });
    connector.submitCandidate(
      session.sessionId,
      session.sessionToken,
      "task-1",
      { summary: "looks good" },
    );
    connector.submitFinding(session.sessionId, session.sessionToken, "task-1", {
      severity: "minor",
    });
    expect(() =>
      connector.submitResult(
        session.sessionId,
        session.sessionToken,
        "task-1",
        { assignmentId: assignment.assignmentId, status: "completed" },
      ),
    ).toThrow("does not match");
    connector.submitResult(session.sessionId, session.sessionToken, "task-1", {
      assignmentId: assignment.assignmentId,
      attemptId: assignment.attemptId,
      runId: assignment.runId,
      taskId: assignment.taskId,
      workerId: assignment.workerId,
      hostId: assignment.hostId,
      credentialProfileId: assignment.credentialProfileId,
      status: "completed",
    });
    connector.reportStatus(session.sessionId, session.sessionToken, {
      status: "waiting",
    });
    connector.releaseAssignment(
      session.sessionId,
      session.sessionToken,
      "task-1",
    );
    expect(() =>
      connector.getAssignment(
        session.sessionId,
        session.sessionToken,
        "task-1",
      ),
    ).toThrow(InteractiveConnectorError);
    now += 20_000;
  });

  it("rejects invalid registration and expired session leases", () => {
    let now = 1_000_000;
    const connector = new InteractiveConnector({
      registrationToken: "register-secret",
      now: () => now,
      idFactory: (prefix) => `${prefix}-1`,
    });
    expect(() =>
      connector.registerSession("wrong", {
        organizationId: "org-1",
        projectId: "project-1",
        workerId: "web-worker",
        credentialProfileId: "profile-1",
        capabilities: [],
      }),
    ).toThrow("authentication");
    const session = connector.registerSession("register-secret", {
      organizationId: "org-1",
      projectId: "project-1",
      workerId: "web-worker",
      credentialProfileId: "profile-1",
      capabilities: [],
      leaseMs: 1_000,
    });
    now += 1_001;
    expect(() =>
      connector.getContext(session.sessionId, session.sessionToken, "missing"),
    ).toThrow("expired");
  });

  it("exposes authenticated task status for the web relay", () => {
    const connector = new InteractiveConnector({
      registrationToken: "relay-token",
      idFactory: (prefix) => `${prefix}-web`,
    });
    connector.registerAssignment({
      taskId: "web-task",
      goalId: "goal-1",
      runId: "run-1",
      organizationId: "org-1",
      projectId: "project-1",
      credentialProfileId: "profile-1",
      objective: "Propose an architecture",
      context: [],
      messages: [{ prompt: "Return a candidate" }],
    });
    expect(
      connector.getAssignmentStatus("relay-token", "web-task"),
    ).toMatchObject({
      status: "queued",
      result: null,
    });
    expect(() => connector.getAssignmentStatus("wrong", "web-task")).toThrow(
      "authentication",
    );
    expect(() =>
      connector.registerAssignment({
        taskId: "web-task",
        goalId: "goal-1",
        runId: "run-1",
        organizationId: "org-1",
        projectId: "project-1",
        credentialProfileId: "profile-1",
        objective: "Duplicate",
        context: [],
        messages: [],
      }),
    ).toThrow("already registered");
  });

  it("never claims a task from another project", () => {
    const connector = new InteractiveConnector({
      registrationToken: "register-secret",
      idFactory: (prefix) => `${prefix}-1`,
    });
    connector.registerAssignment({
      taskId: "other-task",
      goalId: "goal-2",
      runId: "run-2",
      organizationId: "org-2",
      projectId: "project-2",
      objective: "Private task",
      context: [],
      messages: [],
    });
    const session = connector.registerSession("register-secret", {
      organizationId: "org-1",
      projectId: "project-1",
      workerId: "web-worker",
      credentialProfileId: "profile-1",
      capabilities: [],
    });
    expect(() =>
      connector.claimAssignment(session.sessionId, session.sessionToken),
    ).toThrow("not available");
    expect(() =>
      connector.claimAssignment(
        session.sessionId,
        session.sessionToken,
        "other-task",
      ),
    ).toThrow("outside the session workspace");
  });

  it("does not allow a session to reuse another Credential Profile", () => {
    const connector = new InteractiveConnector({
      registrationToken: "register-secret",
    });
    connector.registerAssignment({
      taskId: "profile-task",
      goalId: "goal-1",
      runId: "run-1",
      organizationId: "org-1",
      projectId: "project-1",
      credentialProfileId: "profile-owner",
      objective: "Use the private web account",
      context: [],
      messages: [],
    });
    const session = connector.registerSession("register-secret", {
      organizationId: "org-1",
      projectId: "project-1",
      workerId: "web-worker",
      credentialProfileId: "profile-other",
      capabilities: [],
    });
    expect(() =>
      connector.claimAssignment(
        session.sessionId,
        session.sessionToken,
        "profile-task",
      ),
    ).toThrow("credential Profile");
  });

  it("isolates simultaneous same-Worker sessions for different users", () => {
    const connector = new InteractiveConnector({
      registrationToken: "register-secret",
      idFactory: (prefix) => `${prefix}-${crypto.randomUUID()}`,
    });
    connector.registerAssignment({
      taskId: "user-a-task",
      goalId: "goal-1",
      runId: "run-1",
      organizationId: "org-1",
      projectId: "project-1",
      workerId: "web-worker",
      credentialProfileId: "shared-profile",
      requestedByUserId: "user-a",
      sessionMode: "fresh",
      objective: "User A private task",
      context: [],
      messages: [],
    });
    connector.registerAssignment({
      taskId: "user-b-task",
      goalId: "goal-1",
      runId: "run-1",
      organizationId: "org-1",
      projectId: "project-1",
      workerId: "web-worker",
      credentialProfileId: "shared-profile",
      requestedByUserId: "user-b",
      sessionMode: "fresh",
      objective: "User B private task",
      context: [],
      messages: [],
    });
    const userA = connector.registerSession("register-secret", {
      organizationId: "org-1",
      projectId: "project-1",
      workerId: "web-worker",
      credentialProfileId: "shared-profile",
      requestedByUserId: "user-a",
      sessionMode: "fresh",
      capabilities: [],
    });
    const userB = connector.registerSession("register-secret", {
      organizationId: "org-1",
      projectId: "project-1",
      workerId: "web-worker",
      credentialProfileId: "shared-profile",
      requestedByUserId: "user-b",
      sessionMode: "fresh",
      capabilities: [],
    });
    expect(
      connector.claimAssignment(
        userA.sessionId,
        userA.sessionToken,
        "user-a-task",
      ).requestedByUserId,
    ).toBe("user-a");
    expect(
      connector.claimAssignment(
        userB.sessionId,
        userB.sessionToken,
        "user-b-task",
      ).requestedByUserId,
    ).toBe("user-b");
    expect(userA.namespace).not.toBe(userB.namespace);
    expect(() =>
      connector.getContext(userA.sessionId, userA.sessionToken, "user-b-task"),
    ).toThrow("session");
  });

  it("reports quota exhaustion without executing a web assignment", () => {
    const connector = new InteractiveConnector({
      registrationToken: "register-secret",
    });
    connector.registerAssignment({
      taskId: "quota-task",
      goalId: "goal-1",
      runId: "run-1",
      organizationId: "org-1",
      projectId: "project-1",
      credentialProfileId: "profile-quota",
      objective: "Use a quota-limited account",
      context: [],
      messages: [],
    });
    const session = connector.registerSession("register-secret", {
      organizationId: "org-1",
      projectId: "project-1",
      workerId: "web-worker",
      credentialProfileId: "profile-quota",
      capabilities: [],
      quotaRemaining: 0,
    });
    expect(() =>
      connector.claimAssignment(
        session.sessionId,
        session.sessionToken,
        "quota-task",
      ),
    ).toThrow("quota");
    expect(
      connector.getAssignmentStatus("register-secret", "quota-task"),
    ).toMatchObject({ statusReport: { status: "quota_exceeded" } });
  });
});
