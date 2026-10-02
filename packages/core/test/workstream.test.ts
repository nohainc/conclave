import { describe, expect, it } from "vitest";
import {
  type DiscussionMessage,
  type ProjectMembership,
  type WorkRequest,
  type Workstream,
  type WorkstreamExecutionLease,
  type WorkstreamExecutionPolicy,
  type BuiltinWorkflowDefinition,
  BUILTIN_WORKFLOWS,
  BUILTIN_WORKFLOW_CATALOG,
  deserializeEntity,
  serializeEntity,
  validateBuiltinWorkflowDefinition,
  validateWorkRequest,
  validateWorkstream,
  validateWorkstreamLeases,
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

const statefulPolicy: WorkstreamExecutionPolicy = {
  mode: "stateful",
  primaryWorkspaceId: "workspace-1",
};

describe("Workstream domain", () => {
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

  it("intersects Project roles with selected Project members and permissions", () => {
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

  it("requires a Primary Workspace for stateful Work Requests", () => {
    const request: WorkRequest = {
      id: "request-1",
      workstreamId: "workstream-1",
      requestedByUserId: "collaborator-1",
      mode: "stateful",
      workflowId: "direct",
      workflowVersion: 1,
      workflowSnapshot: BUILTIN_WORKFLOWS.direct,
      status: "queued",
      primaryWorkspaceId: "workspace-1",
      input: {},
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:00:00.000Z",
    };
    expect(() => validateWorkRequest(request, statefulPolicy)).not.toThrow();
    expect(() =>
      validateWorkRequest(
        { ...request, primaryWorkspaceId: null },
        statefulPolicy,
      ),
    ).toThrow(/requires a Primary Workspace/);
  });

  it("enforces one active runtime lease per Workstream", () => {
    const leases: WorkstreamExecutionLease[] = [
      {
        id: "lease-1",
        workstreamId: "workstream-1",
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
    expect(() => validateWorkstreamLeases(workstream, leases)).not.toThrow();
    expect(() =>
      validateWorkstreamLeases(workstream, [
        ...leases,
        { ...lease, id: "lease-2", fencingToken: 2 },
      ]),
    ).toThrow(/only one active execution lease/);
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
    const encoded = serializeEntity(message);
    expect(deserializeEntity<DiscussionMessage>(encoded)).toEqual(message);
    expect(() => deserializeEntity("[]")).toThrow(/must be an object/);
  });

  it("admits only canonical built-in Workflows and fixed step semantics", () => {
    expect(Object.values(BUILTIN_WORKFLOWS)).toEqual(
      Object.values(BUILTIN_WORKFLOW_CATALOG),
    );
    for (const definition of Object.values(BUILTIN_WORKFLOWS)) {
      expect(() => validateBuiltinWorkflowDefinition(definition)).not.toThrow();
      for (const step of definition.steps) {
        expect(step).toMatchObject({
          executionClass: expect.any(String),
          requiredCapabilities: expect.any(Array),
          readWritePolicy: expect.any(String),
          timeoutMs: expect.any(Number),
          promptProfileVersion: expect.any(String),
          inputsFrom: expect.any(Array),
          resultSemantics: expect.any(String),
        });
      }
    }
    expect(
      BUILTIN_WORKFLOWS.full_cycle.steps.map((step) => [
        step.kind,
        step.inputsFrom,
      ]),
    ).toEqual([
      ["research", []],
      ["plan", ["research"]],
      ["implement", ["research", "plan"]],
      ["test", ["plan", "implement"]],
      ["verify", ["research", "plan", "implement", "test"]],
    ]);
    expect(BUILTIN_WORKFLOWS.implement_verify.steps[1]?.inputsFrom).toEqual([
      "implement",
    ]);
    const custom: BuiltinWorkflowDefinition = {
      ...BUILTIN_WORKFLOWS.implement_verify,
      steps: [
        {
          ...BUILTIN_WORKFLOWS.implement_verify.steps[0]!,
          kind: "research",
        },
      ],
    };
    expect(() => validateBuiltinWorkflowDefinition(custom)).toThrow(
      /canonical version/,
    );
    const openEndedRole = {
      ...BUILTIN_WORKFLOWS.direct,
      steps: [
        {
          ...BUILTIN_WORKFLOWS.direct.steps[0]!,
          role: "senior_magic_reviewer",
        },
      ],
    } as unknown as BuiltinWorkflowDefinition;
    expect(() => validateBuiltinWorkflowDefinition(openEndedRole)).toThrow(
      /unsupported fields/,
    );
  });

  it("snapshots the selected built-in Workflow version", () => {
    const request: WorkRequest = {
      id: "request-1",
      workstreamId: "workstream-1",
      requestedByUserId: "collaborator-1",
      mode: "stateful",
      workflowId: "direct",
      workflowVersion: 1,
      workflowSnapshot: BUILTIN_WORKFLOWS.direct,
      status: "queued",
      primaryWorkspaceId: "workspace-1",
      input: {},
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:00:00.000Z",
    };
    expect(() => validateWorkRequest(request, statefulPolicy)).not.toThrow();
  });
});
