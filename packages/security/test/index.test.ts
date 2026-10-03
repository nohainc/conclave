import { describe, expect, it } from "vitest";
import {
  AuthorizationError,
  authorize,
  authorizeProfileAdmin,
  authorizeProjectMembership,
  authorizeProjectOwner,
  authorizeWorkspaceOwner,
  computePackageDigest,
  extractBearerToken,
  hashToken,
  resolveProjectSecurityContextFromIdentity,
  type DatabaseAdapter,
  type DatabaseStatement,
  type SecurityContext,
} from "../src/index.js";

const user = {
  id: "user-1",
  email: "one@example.test",
  displayName: "User One",
  status: "active" as const,
};
const context: SecurityContext = {
  userId: user.id,
  user,
  projectRoles: { "project-1": "collaborator", "project-2": "viewer" },
  sessionId: "session-1",
  clientType: "web",
};

function database(firstResult: unknown): DatabaseAdapter {
  const statement: DatabaseStatement = {
    bind: () => statement,
    first: async () => firstResult as never,
    all: async () => ({ results: [] }),
    run: async () => ({ success: true }),
  };
  return { prepare: () => statement };
}

describe("current authorization model", () => {
  it("authorizes actions from current Project roles only", () => {
    expect(() =>
      authorize(context, "projects:write", "project-1"),
    ).not.toThrow();
    expect(() => authorize(context, "runs:control", "project-1")).toThrow(
      AuthorizationError,
    );
    expect(() => authorize(context, "projects:write", "project-2")).toThrow(
      AuthorizationError,
    );
    expect(() =>
      authorize(context, "projects:read", "unrelated-project"),
    ).toThrow(AuthorizationError);
  });

  it("rechecks Project membership and ownership in the database", async () => {
    const db = database({ role: "owner" });
    await expect(
      authorizeProjectMembership(db, context, "project-1", "projects:manage"),
    ).resolves.toEqual({ role: "owner" });
    await expect(
      authorizeProjectOwner(db, context, "project-1"),
    ).resolves.toBeUndefined();
    await expect(
      authorizeProjectMembership(
        database(null),
        context,
        "project-1",
        "projects:read",
      ),
    ).rejects.toBeInstanceOf(AuthorizationError);
  });

  it("authorizes Workspace access by ownership, not membership role", async () => {
    await expect(
      authorizeWorkspaceOwner(
        database({ id: "workspace-1" }),
        context,
        "workspace-1",
      ),
    ).resolves.toBeUndefined();
    await expect(
      authorizeWorkspaceOwner(database(null), context, "workspace-1"),
    ).rejects.toBeInstanceOf(AuthorizationError);
  });

  it("keeps Profile administration separate from Project and Workspace roles", () => {
    expect(() => authorizeProfileAdmin(context, ["user-1"])).not.toThrow();
    expect(() => authorizeProfileAdmin(context, ["another-user"])).toThrow(
      AuthorizationError,
    );
    expect(() =>
      authorizeProfileAdmin(context, ["user-1"], "profiles:release:manage"),
    ).not.toThrow();
    expect(() =>
      authorizeProfileAdmin(context, ["admin-only"], "profiles:release:manage"),
    ).toThrow(AuthorizationError);

    // Desktop clients must possess conclave.profile-lab.management audience
    const profileLabDesktopContext: SecurityContext = {
      ...context,
      clientType: "desktop",
      audience: "conclave.profile-lab.management",
    };
    expect(() =>
      authorizeProfileAdmin(profileLabDesktopContext, ["user-1"]),
    ).not.toThrow();

    const workspaceDesktopContext: SecurityContext = {
      ...context,
      clientType: "desktop",
      audience: "conclave.desktop.management",
    };
    expect(() =>
      authorizeProfileAdmin(workspaceDesktopContext, ["user-1"]),
    ).toThrow(AuthorizationError);

    const unspecifiedDesktopContext: SecurityContext = {
      ...context,
      clientType: "desktop",
    };
    expect(() =>
      authorizeProfileAdmin(unspecifiedDesktopContext, ["user-1"]),
    ).toThrow(AuthorizationError);
  });

  it("resolves human identity and Project roles without legacy aliases", async () => {
    let call = 0;
    const db: DatabaseAdapter = {
      prepare: () => {
        const statement: DatabaseStatement = {
          bind: () => statement,
          first: async <T>() =>
            ({
              id: "user-1",
              email: "one@example.test",
              display_name: "User One",
              avatar_url: null,
              status: "active",
            }) as T,
          all: async <T>() =>
            (++call === 1
              ? { results: [{ project_id: "project-1", role: "owner" }] }
              : { results: [] }) as unknown as { results: readonly T[] },
          run: async () => ({ success: true }),
        };
        return statement;
      },
    };
    const resolved = await resolveProjectSecurityContextFromIdentity(db, {
      userId: "user-1",
      email: "one@example.test",
      name: "User One",
      sessionId: "session-1",
    });
    expect(resolved.projectRoles).toEqual({ "project-1": "owner" });
    expect(resolved.clientType).toBe("web");
    expect(resolved.audience).toBeUndefined();
    expect(resolved).not.toHaveProperty("authorizationModel");
    expect(resolved).not.toHaveProperty("workspaceRole");
    expect(resolved).not.toHaveProperty("organizationId");

    const desktopResolved = await resolveProjectSecurityContextFromIdentity(
      db,
      {
        userId: "user-1",
        email: "one@example.test",
        name: "User One",
        sessionId: "session-1",
      },
      "desktop",
      "conclave.profile-lab.management",
    );
    expect(desktopResolved.clientType).toBe("desktop");
    expect(desktopResolved.audience).toBe("conclave.profile-lab.management");
  });
});

describe("security token utilities", () => {
  it("hashes tokens and computes package digests", async () => {
    expect(await hashToken("token")).toMatch(/^[a-f0-9]{64}$/);
    expect(await computePackageDigest("content")).toMatch(
      /^sha256:[a-f0-9]{64}$/,
    );
  });

  it("extracts bearer credentials", () => {
    expect(
      extractBearerToken(new Headers({ authorization: "Bearer abc" })),
    ).toBe("abc");
    expect(
      extractBearerToken(new Headers({ authorization: "Basic abc" })),
    ).toBeNull();
  });
});
