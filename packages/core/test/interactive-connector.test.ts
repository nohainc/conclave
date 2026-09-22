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
    connector.registerTask({
      taskId: "task-1",
      goalId: "goal-1",
      runId: "run-1",
      organizationId: "org-1",
      projectId: "project-1",
      objective: "Review the proposal",
      context: [],
      messages: [{ type: "review", text: "Inspect the candidate" }],
    });
    const session = connector.registerSession("register-secret", {
      organizationId: "org-1",
      projectId: "project-1",
      workerId: "web-reviewer",
      capabilities: ["code_review"],
      leaseMs: 10_000,
    });
    expect(
      connector.claimTask(session.sessionId, session.sessionToken).taskId,
    ).toBe("task-1");
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
    connector.reportStatus(session.sessionId, session.sessionToken, {
      status: "waiting",
    });
    connector.releaseTask(session.sessionId, session.sessionToken, "task-1");
    expect(() =>
      connector.getTask(session.sessionId, session.sessionToken, "task-1"),
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
        capabilities: [],
      }),
    ).toThrow("authentication");
    const session = connector.registerSession("register-secret", {
      organizationId: "org-1",
      projectId: "project-1",
      workerId: "web-worker",
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
    connector.registerTask({
      taskId: "web-task",
      goalId: "goal-1",
      runId: "run-1",
      organizationId: "org-1",
      projectId: "project-1",
      objective: "Propose an architecture",
      context: [],
      messages: [{ prompt: "Return a candidate" }],
    });
    expect(connector.getTaskStatus("relay-token", "web-task")).toMatchObject({
      status: "queued",
      result: null,
    });
    expect(() => connector.getTaskStatus("wrong", "web-task")).toThrow(
      "authentication",
    );
    expect(() =>
      connector.registerTask({
        taskId: "web-task",
        goalId: "goal-1",
        runId: "run-1",
        organizationId: "org-1",
        projectId: "project-1",
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
    connector.registerTask({
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
      capabilities: [],
    });
    expect(() =>
      connector.claimTask(session.sessionId, session.sessionToken),
    ).toThrow("not available");
    expect(() =>
      connector.claimTask(
        session.sessionId,
        session.sessionToken,
        "other-task",
      ),
    ).toThrow("outside the session workspace");
  });
});
