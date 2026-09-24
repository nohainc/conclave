import { describe, expect, it } from "vitest";
import {
  authorize,
  authorizeProjectMembership,
  authorizeProjectOwner,
  authorizeProjectAccountUse,
  authorizeWorkspaceOwner,
  AuthorizationError,
  resolveProjectSecurityContextFromIdentity,
  type DatabaseAdapter,
  type SecurityContext,
} from "../src/index.js";

type Membership = {
  project_id: string;
  user_id: string;
  role: "owner" | "collaborator" | "viewer";
};

function createDb() {
  const memberships: Membership[] = [
    { project_id: "project-owned", user_id: "user-1", role: "owner" },
    { project_id: "project-collab", user_id: "user-1", role: "collaborator" },
    { project_id: "project-view", user_id: "user-1", role: "viewer" },
  ];
  const workspaceOwners = new Map([["workspace-1", "user-owner"]]);
  const projectOwners = new Map([["project-owned", "user-1"]]);

  const db: DatabaseAdapter = {
    prepare(query: string) {
      let bound: unknown[] = [];
      return {
        bind(...values: unknown[]) {
          bound = values;
          return this;
        },
        async first<T>() {
          if (query.includes("FROM users")) {
            return {
              id: "user-1",
              email: "user-1@example.com",
              display_name: "User One",
              avatar_url: null,
              status: "active",
            } as T;
          }
          if (query.includes("FROM project_memberships")) {
            const membership = memberships.find(
              (item) =>
                item.project_id === bound[0] && item.user_id === bound[1],
            );
            return (membership ? { role: membership.role } : null) as T;
          }
          if (query.includes("FROM execution_workspaces")) {
            const owner = workspaceOwners.get(String(bound[0]));
            return owner === bound[1] ? ({ id: bound[0] } as T) : null;
          }
          if (query.includes("FROM projects")) {
            const owner = projectOwners.get(String(bound[0]));
            return owner === bound[1] ? ({ id: bound[0] } as T) : null;
          }
          return null;
        },
        async all<T>() {
          if (query.includes("FROM project_memberships")) {
            return {
              results: memberships
                .filter((item) => item.user_id === bound[0])
                .map(({ project_id, role }) => ({ project_id, role })),
            } as { results: T[] };
          }
          if (query.includes("FROM execution_workspaces")) {
            return {
              results: [...workspaceOwners.entries()]
                .filter(([, owner]) => owner === bound[0])
                .map(([id]) => ({ id })),
            } as { results: T[] };
          }
          if (query.includes("FROM ai_accounts")) return { results: [] as T[] };
          return { results: [] as T[] };
        },
        async run() {
          return { success: true };
        },
      };
    },
  };
  return { db, memberships };
}

async function context() {
  const { db } = createDb();
  return resolveProjectSecurityContextFromIdentity(db, {
    userId: "user-1",
    email: "user-1@example.com",
    name: "User One",
    sessionId: "session-1",
  });
}

describe("Architecture v5 User + Project authorization", () => {
  it("does not accept Project ID substitution or direct unauthorized URLs", async () => {
    const { db } = createDb();
    const resolved = await resolveProjectSecurityContextFromIdentity(db, {
      userId: "user-1",
      email: "user-1@example.com",
      name: "User One",
      sessionId: "session-1",
    });
    await expect(
      authorizeProjectMembership(
        db,
        resolved,
        "project-not-member",
        "projects:read",
      ),
    ).rejects.toThrow(AuthorizationError);
    expect(resolved.workspaceId).toBe("");
    expect(resolved.authorizationModel).toBe("v5");
    expect(resolved.authorizedProjectIds).toEqual([
      "project-owned",
      "project-collab",
      "project-view",
    ]);
  });

  it("rechecks membership after it is removed during an active session", async () => {
    const state = createDb();
    const resolved = await resolveProjectSecurityContextFromIdentity(state.db, {
      userId: "user-1",
      email: "user-1@example.com",
      name: "User One",
      sessionId: "session-1",
    });
    await expect(
      authorizeProjectMembership(
        state.db,
        resolved,
        "project-collab",
        "projects:write",
      ),
    ).resolves.toEqual({ role: "collaborator" });
    state.memberships.splice(
      0,
      state.memberships.length,
      ...state.memberships.filter(
        (membership) => membership.project_id !== "project-collab",
      ),
    );
    await expect(
      authorizeProjectMembership(
        state.db,
        resolved,
        "project-collab",
        "projects:write",
      ),
    ).rejects.toThrow(AuthorizationError);
  });

  it("denies viewer execution while allowing collaborator Project work", async () => {
    const resolved = await context();
    expect(() => authorize(resolved, "run.start", "project-view")).toThrow(
      AuthorizationError,
    );
    expect(() =>
      authorize(resolved, "run.start", "project-collab"),
    ).not.toThrow();
  });

  it("allows Workspace management only to the Workspace owner", async () => {
    const { db } = createDb();
    const resolved = await context();
    await expect(
      authorizeWorkspaceOwner(db, resolved, "workspace-1", "workspace:manage"),
    ).rejects.toThrow(AuthorizationError);
    const ownerContext = { ...resolved, userId: "user-owner" };
    await expect(
      authorizeWorkspaceOwner(
        db,
        ownerContext,
        "workspace-1",
        "workers:manage",
      ),
    ).resolves.toBeUndefined();
    await expect(
      authorizeWorkspaceOwner(db, resolved, "workspace-1", "workers:manage"),
    ).rejects.toThrow(AuthorizationError);
  });

  it("allows Project deletion only to the Project owner", async () => {
    const { db } = createDb();
    const resolved = await context();
    await expect(
      authorizeProjectOwner(db, resolved, "project-owned"),
    ).resolves.toBeUndefined();
    const collaboratorContext = { ...resolved, userId: "user-owner" };
    await expect(
      authorizeProjectOwner(db, collaboratorContext, "project-owned"),
    ).rejects.toThrow(AuthorizationError);
  });

  it("keeps AI Account use independent and revocable from Project membership", async () => {
    let grantActive = true;
    const db: DatabaseAdapter = {
      prepare(query: string) {
        let bound: unknown[] = [];
        return {
          bind(...values: unknown[]) {
            bound = values;
            return this;
          },
          async first<T>() {
            if (query.includes("FROM ai_accounts")) {
              return {
                owner_user_id: "account-owner",
                status: "ready",
                sharing_mode: "project_shared",
                provider_metadata_json: "{}",
              } as T;
            }
            if (query.includes("FROM project_memberships")) {
              return { role: "collaborator" } as T;
            }
            if (query.includes("FROM project_account_grants") && grantActive) {
              return { id: "grant-1" } as T;
            }
            return null;
          },
          async all<T>() {
            return { results: [] as T[] };
          },
          async run() {
            return { success: true };
          },
        };
      },
    };
    const requester = (await context()) as SecurityContext;
    await expect(
      authorizeProjectAccountUse(db, requester, "project-collab", "account-1"),
    ).resolves.toBeUndefined();
    grantActive = false;
    await expect(
      authorizeProjectAccountUse(db, requester, "project-collab", "account-1"),
    ).rejects.toThrow(AuthorizationError);
  });

  it("rejects provider-private Accounts even when a Project grant exists", async () => {
    const db: DatabaseAdapter = {
      prepare(query: string) {
        return {
          bind() {
            return this;
          },
          async first<T>() {
            if (query.includes("FROM ai_accounts")) {
              return {
                owner_user_id: "account-owner",
                status: "ready",
                sharing_mode: "project_shared",
                provider_metadata_json: JSON.stringify({ providerSharingPolicy: "private_only" }),
              } as T;
            }
            return { role: "collaborator" } as T;
          },
          async all<T>() {
            return { results: [{ id: "grant-1" }] as T[] };
          },
          async run() {
            return { success: true };
          },
        };
      },
    };
    await expect(
      authorizeProjectAccountUse(db, (await context()) as SecurityContext, "project-collab", "account-1"),
    ).rejects.toThrow(AuthorizationError);
  });
});
