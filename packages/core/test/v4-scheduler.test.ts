import { describe, expect, it } from "vitest";
import {
  createAssignmentSnapshot,
  resolveExecutionTarget,
  type AvailableWorkerAccount,
  type CredentialGrant,
  type CredentialProfile,
} from "../src/index.js";

const profile = (id: string, ownerId = "user-owner"): CredentialProfile => ({
  id,
  ownerType: "user",
  ownerId,
  workspaceId: "ws-1",
  workerId: "codex",
  displayName: id,
  authType: "oauth",
  visibility: "workspace",
  createdAt: "2026-09-23T00:00:00Z",
  updatedAt: "2026-09-23T00:00:00Z",
});

const grant = (profileId: string, userId: string): CredentialGrant => ({
  id: `grant-${profileId}-${userId}`,
  credentialProfileId: profileId,
  granteeType: "user",
  granteeId: userId,
  usePermission: "use",
  grantedBy: "user-owner",
  createdAt: "2026-09-23T00:00:00Z",
});

const candidate = (
  overrides: Partial<AvailableWorkerAccount> = {},
): AvailableWorkerAccount => ({
  workerId: "codex",
  hostId: "host-1",
  workerVersion: "1.0.0",
  capabilities: ["research", "code"],
  roles: ["researcher", "implementer"],
  model: "codex-1",
  billingMode: "subscription",
  activeAssignments: 0,
  concurrencyLimit: 2,
  credentialProfile: profile("owner-codex"),
  grants: [],
  ...overrides,
});

describe("v4 dynamic execution resolution", () => {
  it("uses one catalog Worker for different task roles", () => {
    const available = [candidate()];
    expect(
      resolveExecutionTarget(
        {
          role: "researcher",
          capabilities: ["research"],
          requesterUserId: "user-owner",
        },
        available,
      ).status,
    ).toBe("ready");
    expect(
      resolveExecutionTarget(
        {
          role: "implementer",
          capabilities: ["code"],
          requesterUserId: "user-owner",
        },
        available,
      ).status,
    ).toBe("ready");
  });

  it("selects reviewer capability and honors explicit overrides", () => {
    const available = [
      candidate({ workerId: "codex", roles: ["implementer"] }),
      candidate({
        workerId: "reviewer",
        roles: ["reviewer"],
        credentialProfile: profile("reviewer-account"),
      }),
    ];
    const reviewer = resolveExecutionTarget(
      { role: "reviewer", capabilities: [], requesterUserId: "user-owner" },
      available,
    );
    expect(reviewer).toMatchObject({ status: "ready", workerId: "reviewer" });
    const explicit = resolveExecutionTarget(
      {
        role: "implementer",
        capabilities: [],
        requesterUserId: "user-owner",
        explicitWorkerId: "codex",
      },
      available,
    );
    expect(explicit).toMatchObject({
      status: "ready",
      workerId: "codex",
      reason: "explicit",
    });
  });

  it("honors Auto and user subscription/API preference", () => {
    const available = [
      candidate({
        billingMode: "api",
        credentialProfile: profile("api-account"),
      }),
      candidate({
        billingMode: "subscription",
        credentialProfile: profile("subscription-account"),
      }),
    ];
    const automatic = resolveExecutionTarget(
      { requesterUserId: "user-owner" },
      available,
      {},
      { executionPreference: "api" },
    );
    expect(automatic).toMatchObject({
      status: "ready",
      credentialProfileId: "api-account",
    });
  });

  it("resolves a granted account without exposing its secret", () => {
    const shared = candidate({
      credentialProfile: profile("shared-codex"),
      grants: [grant("shared-codex", "user-consumer")],
    });
    const resolved = resolveExecutionTarget(
      { requesterUserId: "user-consumer" },
      [shared],
    );
    expect(resolved).toMatchObject({
      status: "ready",
      credentialProfileId: "shared-codex",
    });
  });

  it("returns setup_required when a required credential is unavailable", () => {
    const result = resolveExecutionTarget(
      { requesterUserId: "user-consumer", explicitWorkerId: "codex" },
      [candidate()],
    );
    expect(result).toEqual({
      status: "setup_required",
      workerId: "codex",
      reason: "missing_credential",
    });
  });

  it("skips offline Hosts, installing Workers, full capacity, budget, and independence conflicts", () => {
    const available = [
      candidate({ hostId: "offline", hostStatus: "offline" }),
      candidate({
        workerVersion: "installing",
        installationStatus: "installing",
      }),
      candidate({ hostId: "busy", activeAssignments: 2, concurrencyLimit: 2 }),
      candidate({ hostId: "excluded", independenceKey: "account-a" }),
      candidate({ hostId: "over-budget", estimatedCostMicros: 5000 }),
      candidate({
        hostId: "ready",
        independenceKey: "account-b",
        estimatedCostMicros: 10,
      }),
    ];
    const result = resolveExecutionTarget(
      {
        requesterUserId: "user-owner",
        excludeIndependenceKeys: ["account-a"],
        budgetRemainingMicros: 100,
      },
      available,
    );
    expect(result).toMatchObject({ status: "ready", hostId: "ready" });
  });

  it("creates an immutable v4 assignment snapshot", () => {
    const target = resolveExecutionTarget(
      { requesterUserId: "user-owner", role: "researcher" },
      [candidate()],
    );
    if (target.status !== "ready") throw new Error("expected target");
    const snapshot = createAssignmentSnapshot({
      assignmentId: "assignment-1",
      workspaceId: "ws-1",
      projectId: "project-1",
      runId: "run-1",
      taskId: "task-1",
      attemptId: "attempt-1",
      requestedByUserId: "user-owner",
      target,
      model: "codex-1",
      config: { temperature: 0 },
      sessionPolicy: "isolated_workspace",
      permissions: ["repository:read"],
      contextRefs: [{ uri: "repo://project-1" }],
      timeoutMs: 60_000,
      idempotencyKey: "idempotency-1",
      input: { objective: "Research" },
      now: "2026-09-23T00:00:00Z",
    });
    expect(snapshot).toMatchObject({
      hostId: "host-1",
      workerId: "codex",
      credentialProfileId: "owner-codex",
      resolvedWorkerVersion: "1.0.0",
      requestedByUserId: "user-owner",
    });
  });
});
