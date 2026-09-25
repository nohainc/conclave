import { describe, expect, it } from "vitest";
import {
  type DiscussionMessage,
  type ProjectMembership,
  type WorkRequest,
  type Workstream,
  type WorkstreamCheckout,
  type WorkstreamExecutionLease,
  type WorkstreamExecutionPolicy,
  type WorkstreamCheckpoint,
  type WorkflowVersion,
  deserializeV6Entity,
  serializeV6Entity,
  validateNextWorkflowVersion,
  validateWorkRequest,
  validateWorkstream,
  validateWorkstreamCheckpoints,
  validateWorkstreamLeases,
  validateWorkflowVersion,
  canDiscussWorkstream,
  canExecuteWorkstream,
  canManageWorkstream,
  canViewWorkstream,
} from "../src/index.js";

const memberships: ProjectMembership[] = [
  {
    id: "membership-owner",
    projectId: "project-1",
    userId: "owner-1",
    role: "owner",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
  },
  {
    id: "membership-collaborator",
    projectId: "project-1",
    userId: "collaborator-1",
    role: "collaborator",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
  },
  {
    id: "membership-viewer",
    projectId: "project-1",
    userId: "viewer-1",
    role: "viewer",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
  },
];

const workstream: Workstream = {
  id: "workstream-1",
  projectId: "project-1",
  name: "Authentication",
  status: "active",
  accessPolicy: {
    allowedUserIds: ["owner-1", "collaborator-1"],
    allowedProjectRoles: ["owner", "collaborator"],
    allowedPermissions: ["repository:read"],
  },
  lead: {
    userId: "collaborator-1",
    assignedAt: "2026-01-01T00:00:00.000Z",
    assignedByUserId: "owner-1",
  },
  createdAt: "2026-01-01T00:00:00.000Z",
  updatedAt: "2026-01-01T00:00:00.000Z",
};

const checkout: WorkstreamCheckout = {
  id: "checkout-1",
  workstreamId: "workstream-1",
  workspaceId: "workspace-1",
  repositoryId: "repo-1",
  revision: "abc123",
  relativePath: "workstreams/auth",
  status: "ready",
  createdAt: "2026-01-01T00:00:00.000Z",
  updatedAt: "2026-01-01T00:00:00.000Z",
};

const statefulPolicy: WorkstreamExecutionPolicy = {
  mode: "stateful",
  primaryWorkspaceId: "workspace-1",
  requireCheckout: true,
  maxConcurrentWorkRequests: 1,
};

describe("v6 Workstream domain", () => {
  it("requires a Project owner or collaborator as the lead", () => {
    expect(() => validateWorkstream(workstream, memberships)).not.toThrow();
    expect(() =>
      validateWorkstream(
        { ...workstream, lead: { ...workstream.lead, userId: "viewer-1" } },
        memberships,
      ),
    ).toThrow(/lead must be a Project owner or collaborator/);
  });

  it("prevents Workstream access from expanding Project membership", () => {
    expect(() =>
      validateWorkstream(
        {
          ...workstream,
          accessPolicy: {
            ...workstream.accessPolicy,
            allowedUserIds: ["viewer-1"],
          },
        },
        memberships,
      ),
    ).toThrow(/cannot expand Project membership/);
  });

  it("intersects Project roles with selected Workstream members and permissions", () => {
    const restricted = {
      ...workstream,
      accessPolicy: {
        allowedUserIds: ["collaborator-1", "viewer-1"],
        allowedProjectRoles: ["collaborator", "viewer"] as const,
        allowedPermissions: ["view", "discuss"] as const,
      },
    };
    const owner = memberships[0]!;
    const collaborator = memberships[1]!;
    const viewer = memberships[2]!;

    expect(canViewWorkstream(owner.userId, owner, restricted)).toBe(true);
    expect(
      canViewWorkstream(collaborator.userId, collaborator, restricted),
    ).toBe(true);
    expect(
      canDiscussWorkstream(collaborator.userId, collaborator, restricted),
    ).toBe(true);
    expect(
      canExecuteWorkstream(collaborator.userId, collaborator, restricted),
    ).toBe(false);
    expect(canViewWorkstream(viewer.userId, viewer, restricted)).toBe(true);
    expect(canDiscussWorkstream(viewer.userId, viewer, restricted)).toBe(false);
    expect(canExecuteWorkstream(viewer.userId, viewer, restricted)).toBe(false);
  });

  it("removes access with Project membership and gives the lead management authority", () => {
    const collaborator = memberships[1]!;
    expect(
      canManageWorkstream(collaborator.userId, collaborator, workstream),
    ).toBe(true);
    expect(canManageWorkstream("removed-user", undefined, workstream)).toBe(
      false,
    );
    expect(canViewWorkstream("removed-user", undefined, workstream)).toBe(
      false,
    );
    expect(canExecuteWorkstream("viewer-1", memberships[2], workstream)).toBe(
      false,
    );
  });

  it("requires Primary Workspace and Checkout for stateful Work Requests", () => {
    const request: WorkRequest = {
      id: "request-1",
      workstreamId: "workstream-1",
      requestedByUserId: "collaborator-1",
      mode: "stateful",
      workflowDefinitionId: "workflow-1",
      workflowVersionId: "workflow-version-1",
      workflowVersionSnapshot: {
        id: "workflow-version-1",
        workflowDefinitionId: "workflow-1",
        version: 1,
        steps: [
          {
            id: "implementation",
            name: "Implementation",
            role: "implementation",
            requiredCapabilities: [],
            executionClass: "stateful_workstream",
            order: 0,
            dependsOn: [],
            independentFrom: [],
            approval: "none",
            timeoutMs: 900000,
            outputContract: {
              contentType: "application/json",
              requiredFields: ["summary"],
              artifactTypes: [],
            },
          },
        ],
        createdByUserId: "owner-1",
        createdAt: "2026-01-01T00:00:00.000Z",
      },
      status: "queued",
      primaryWorkspaceId: "workspace-1",
      checkoutId: "checkout-1",
      input: {},
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:00:00.000Z",
    };
    expect(() => validateWorkRequest(request, statefulPolicy)).toThrow(
      /historical Checkout control plane/,
    );
    expect(() =>
      validateWorkRequest({ ...request, checkoutId: null }, statefulPolicy),
    ).not.toThrow();
  });

  it("enforces one active lease and linear checkpoints per Checkout", () => {
    const leases: WorkstreamExecutionLease[] = [
      {
        id: "lease-1",
        workstreamId: "workstream-1",
        checkoutId: "checkout-1",
        workRequestId: "request-1",
        workspaceId: "workspace-1",
        fencingToken: 1,
        status: "active",
        acquiredAt: "2026-01-01T00:00:00.000Z",
        expiresAt: "2026-01-01T01:00:00.000Z",
        releasedAt: null,
      },
    ];
    const lease = leases[0]!;
    expect(() => validateWorkstreamLeases(checkout, leases)).not.toThrow();
    expect(() =>
      validateWorkstreamLeases(checkout, [
        ...leases,
        { ...lease, id: "lease-2", fencingToken: 2 },
      ]),
    ).toThrow(/only one active execution lease/);

    const checkpoint = (sequence: number): WorkstreamCheckpoint => ({
      id: `checkpoint-${sequence}`,
      workstreamId: "workstream-1",
      checkoutId: "checkout-1",
      sequence,
      revision: `rev-${sequence}`,
      summary: `checkpoint ${sequence}`,
      createdByWorkRequestId: "request-1",
      createdAt: "2026-01-01T00:00:00.000Z",
    });
    expect(() =>
      validateWorkstreamCheckpoints(checkout, [checkpoint(1), checkpoint(2)]),
    ).not.toThrow();
    expect(() =>
      validateWorkstreamCheckpoints(checkout, [checkpoint(1), checkpoint(3)]),
    ).toThrow(/checkpoint sequence must be linear/);
  });

  it("serializes and restores domain entities without persistence types", () => {
    const message: DiscussionMessage = {
      id: "message-1",
      workstreamId: "workstream-1",
      authorUserId: "collaborator-1",
      body: "Ready for review",
      createdAt: "2026-01-01T00:00:00.000Z",
      editedAt: null,
    };
    const encoded = serializeV6Entity(message);
    expect(deserializeV6Entity<DiscussionMessage>(encoded)).toEqual(message);
    expect(() => deserializeV6Entity("[]")).toThrow(/must be an object/);
  });

  it("validates DAGs, cycles, stateful ordering, and immutable versions", () => {
    const step = (
      id: string,
      order: number,
      executionClass: "stateless_read" | "stateful_workstream",
      dependsOn: readonly string[] = [],
    ): WorkflowVersion["steps"][number] => ({
      id,
      name: id,
      role: id,
      requiredCapabilities: [],
      executionClass,
      order,
      dependsOn,
      independentFrom: [],
      approval: "none",
      timeoutMs: 1000,
      outputContract: {
        contentType: "application/json",
        requiredFields: [],
        artifactTypes: [],
      },
    });
    const version: WorkflowVersion = {
      id: "workflow-version-2",
      workflowDefinitionId: "workflow-1",
      version: 2,
      steps: [
        step("research", 0, "stateless_read"),
        step("implementation", 1, "stateful_workstream", ["research"]),
      ],
      createdByUserId: "owner-1",
      createdAt: "2026-01-01T00:00:00.000Z",
    };
    expect(() => validateWorkflowVersion(version)).not.toThrow();
    expect(() =>
      validateWorkflowVersion({
        ...version,
        steps: [
          step("research", 0, "stateless_read", ["implementation"]),
          step("implementation", 1, "stateful_workstream", ["research"]),
        ],
      }),
    ).toThrow(/cycle/);
    expect(() =>
      validateWorkflowVersion({
        ...version,
        steps: [
          step("implementation", 0, "stateful_workstream", ["research"]),
          step("research", 1, "stateless_read"),
        ],
      }),
    ).toThrow(/execute before/);
    expect(() =>
      validateNextWorkflowVersion(
        { ...version, id: "workflow-version-1", version: 1 },
        version,
      ),
    ).not.toThrow();
    expect(() =>
      validateNextWorkflowVersion(version, { ...version, id: version.id }),
    ).toThrow(/next immutable version/);
  });

  it("ships all requested built-in workflow versions", async () => {
    const { BUILT_IN_WORKFLOW_NAMES, BUILT_IN_WORKFLOW_VERSIONS } =
      await import("../src/index.js");
    expect(Object.keys(BUILT_IN_WORKFLOW_VERSIONS)).toEqual([
      ...BUILT_IN_WORKFLOW_NAMES,
    ]);
    for (const version of Object.values(BUILT_IN_WORKFLOW_VERSIONS)) {
      expect(() => validateWorkflowVersion(version)).not.toThrow();
    }
  });
});
