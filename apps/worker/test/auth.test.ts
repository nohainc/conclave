import { describe, expect, it } from "vitest";
import {
  buildBetterAuthOptions,
  IdentityService,
  listPendingInvitations,
  provisionConclaveUser,
  safeAuthReturnTo,
  type AuthenticatedIdentity,
} from "../src/auth/index.js";
import { requireSameOriginForCookieMutation } from "../src/routes/handlers.js";

describe("IdentityService", () => {
  it("keeps social login return paths same-origin", () => {
    const request = new Request(
      "https://app.conclave.test/api/auth/sign-in/github",
    );
    expect(safeAuthReturnTo(request, "/projects/p-1/chats/c-1")).toBe(
      "/projects/p-1/chats/c-1",
    );
    expect(safeAuthReturnTo(request, "https://evil.example/steal")).toBe("/");
    expect(safeAuthReturnTo(request, "/api/auth/sign-out")).toBe("/");
  });

  it("configures Better Auth against the clean Conclave core tables", () => {
    const options = buildBetterAuthOptions({
      CONCLAVE_DB: {} as D1Database,
      CONCLAVE_ENVIRONMENT: "development",
      BETTER_AUTH_SECRET: "a-secure-development-secret-that-is-long-enough",
      GITHUB_CLIENT_ID: "github-client-id",
      GITHUB_CLIENT_SECRET: "github-client-secret",
      GOOGLE_CLIENT_ID: "google-client-id",
      GOOGLE_CLIENT_SECRET: "google-client-secret",
    });

    expect(options.user?.modelName).toBe("users");
    expect(options.user?.fields).toMatchObject({
      name: "display_name",
      emailVerified: "email_verified",
      image: "avatar_url",
    });
    expect(options.account?.modelName).toBe("auth_accounts");
    expect(options.account?.encryptOAuthTokens).toBe(true);
    expect(options.account?.accountLinking).toMatchObject({
      enabled: true,
      disableImplicitLinking: true,
      trustedProviders: ["github", "google"],
      allowDifferentEmails: false,
    });
    expect(options.session?.modelName).toBe("auth_sessions");
    expect(options.verification?.modelName).toBe("auth_verifications");
    expect(options.plugins).toHaveLength(1);
    expect(options.plugins?.[0]).toMatchObject({ id: "passkey" });
    expect(options.session).toMatchObject({
      expiresIn: 60 * 60 * 24 * 14,
      updateAge: 60 * 60 * 24,
      disableSessionRefresh: false,
      cookieCache: { enabled: false },
    });
    expect(options.trustedOrigins).toContain("https://app.conclaveax.com");
    expect(options.advanced).toMatchObject({
      useSecureCookies: false,
      defaultCookieAttributes: {
        httpOnly: true,
        sameSite: "Lax",
        path: "/",
      },
    });
    const productionOptions = buildBetterAuthOptions({
      CONCLAVE_DB: {} as D1Database,
      CONCLAVE_ENVIRONMENT: "production",
      BETTER_AUTH_SECRET: "a-secure-production-secret-that-is-long-enough",
      BETTER_AUTH_URL: "https://app.conclaveax.com",
    });
    expect(productionOptions.advanced?.useSecureCookies).toBe(true);
    expect(options.socialProviders).toMatchObject({
      github: {
        scope: ["user:email"],
      },
      google: {
        scope: ["email", "profile"],
      },
    });
    expect(Object.keys(options.socialProviders ?? {})).toEqual([
      "github",
      "google",
    ]);
  });

  it("maps a Better Auth session to the application identity contract", async () => {
    const service = new IdentityService(() => ({
      api: {
        getSession: async () => ({
          user: {
            id: "user-1",
            email: "person@example.test",
            name: "Person",
          },
          session: { id: "session-1" },
        }),
      },
    }));

    const identity = await service.resolve(
      new Request("https://conclave.test/api/projects", {
        headers: { cookie: "better-auth.session_token=opaque" },
      }),
      {
        CONCLAVE_DB: {} as D1Database,
        CONCLAVE_ENVIRONMENT: "development",
      },
    );

    const expected: AuthenticatedIdentity = {
      userId: "user-1",
      email: "person@example.test",
      name: "Person",
      sessionId: "session-1",
    };
    expect(identity).toEqual(expected);
  });

  it("returns null when Better Auth has no session", async () => {
    const service = new IdentityService(() => ({
      api: { getSession: async () => null },
    }));

    await expect(
      service.resolve(new Request("https://conclave.test/api/projects"), {
        CONCLAVE_DB: {} as D1Database,
        CONCLAVE_ENVIRONMENT: "development",
      }),
    ).resolves.toBeNull();
  });

  it("does not accept a revoked or expired Better Auth session", async () => {
    const revoked = new IdentityService(() => ({
      api: { getSession: async () => null },
    }));
    await expect(
      revoked.resolve(new Request("https://conclave.test/api/session"), {
        CONCLAVE_DB: {} as D1Database,
        CONCLAVE_ENVIRONMENT: "production",
      }),
    ).resolves.toBeNull();
  });

  it("keeps concurrent Better Auth sessions distinct and prevents fixation", async () => {
    const sessions = new Map([
      ["new-cookie", "session-new"],
      ["second-cookie", "session-second"],
    ]);
    const service = new IdentityService(() => ({
      api: {
        getSession: async ({ headers }) => {
          const sessionId = sessions.get(headers.get("cookie") ?? "");
          return sessionId
            ? {
                user: {
                  id: "user-1",
                  email: "person@example.test",
                  name: "Person",
                },
                session: { id: sessionId },
              }
            : null;
        },
      },
    }));

    await expect(
      service.resolve(
        new Request("https://conclave.test/api/session", {
          headers: { cookie: "old-cookie" },
        }),
        {
          CONCLAVE_DB: {} as D1Database,
          CONCLAVE_ENVIRONMENT: "production",
        },
      ),
    ).resolves.toBeNull();
    await expect(
      service.resolve(
        new Request("https://conclave.test/api/session", {
          headers: { cookie: "new-cookie" },
        }),
        {
          CONCLAVE_DB: {} as D1Database,
          CONCLAVE_ENVIRONMENT: "production",
        },
      ),
    ).resolves.toMatchObject({ sessionId: "session-new" });
    await expect(
      service.resolve(
        new Request("https://conclave.test/api/session", {
          headers: { cookie: "second-cookie" },
        }),
        {
          CONCLAVE_DB: {} as D1Database,
          CONCLAVE_ENVIRONMENT: "production",
        },
      ),
    ).resolves.toMatchObject({ sessionId: "session-second" });
  });

  it("enforces same-origin mutations for cookie sessions", () => {
    expect(() =>
      requireSameOriginForCookieMutation(
        new Request("https://app.conclave.test/api/projects", {
          method: "POST",
          headers: {
            cookie: "better-auth.session_token=opaque",
            origin: "https://evil.example",
          },
        }),
      ),
    ).toThrow("Same-origin request required");

    expect(() =>
      requireSameOriginForCookieMutation(
        new Request("https://app.conclave.test/api/projects", {
          method: "POST",
          headers: {
            cookie: "better-auth.session_token=opaque",
            origin: "https://app.conclave.test",
          },
        }),
      ),
    ).not.toThrow();

    expect(() =>
      requireSameOriginForCookieMutation(
        new Request("https://app.conclave.test/api/projects", {
          method: "POST",
          headers: { cookie: "better-auth.session_token=opaque" },
        }),
      ),
    ).toThrow("Same-origin request required");
  });

  it("provisions a deterministic personal workspace idempotently", async () => {
    const queries: string[] = [];
    let membershipExists = false;
    const db = {
      prepare(query: string) {
        queries.push(query);
        let values: unknown[] = [];
        return {
          bind(...bound: unknown[]) {
            values = bound;
            return this;
          },
          async first<T>() {
            if (query.includes("FROM workspace_memberships")) {
              return membershipExists
                ? ({ workspace_id: "existing-workspace" } as T)
                : null;
            }
            return null;
          },
          async all<T>() {
            return { results: [] as readonly T[] };
          },
          async run() {
            return { values };
          },
        };
      },
      async batch(statements: readonly unknown[]) {
        expect(statements).toHaveLength(2);
        membershipExists = true;
      },
    };
    const identity = {
      userId: "user-1",
      email: "person@example.test",
      name: "Person",
      sessionId: "session-1",
    };

    await provisionConclaveUser(db, identity, "2026-09-23T00:00:00.000Z");
    await provisionConclaveUser(db, identity, "2026-09-23T00:01:00.000Z");

    expect(
      queries.filter((query) => query.includes("INSERT INTO workspaces")),
    ).toHaveLength(1);
    expect(
      queries.filter((query) => query.includes("INSERT INTO users")),
    ).toHaveLength(2);
  });

  it("returns pending invitations without accepting them", async () => {
    const db = {
      prepare(query: string) {
        return {
          bind() {
            return this;
          },
          async first() {
            return null;
          },
          async all<T>() {
            expect(query).toContain("status = 'pending'");
            return {
              results: [
                {
                  id: "inv-1",
                  workspaceId: "ws-team",
                  projectId: null,
                  email: "person@example.test",
                  role: "member",
                  status: "pending",
                  expiresAt: "2099-01-01T00:00:00.000Z",
                } as unknown as T,
              ],
            };
          },
          async run() {
            return {};
          },
        };
      },
      async batch() {},
    };

    await expect(
      listPendingInvitations(
        db,
        "person@example.test",
        "2026-09-23T00:00:00.000Z",
      ),
    ).resolves.toEqual([
      expect.objectContaining({ id: "inv-1", status: "pending" }),
    ]);
  });

  it("does not expose a pending invitation to a different email", async () => {
    let boundEmail: unknown;
    const db = {
      prepare(query: string) {
        return {
          bind(...values: unknown[]) {
            boundEmail = values[0];
            expect(query).toContain("lower(email) = lower(?1)");
            return this;
          },
          async first() {
            return null;
          },
          async all<T>() {
            return {
              results:
                boundEmail === "attacker@example.test"
                  ? []
                  : ([{ id: "inv-1" }] as T[]),
            } as { results: T[] };
          },
          async run() {
            return {};
          },
        };
      },
      async batch() {},
    };

    await expect(
      listPendingInvitations(
        db,
        "attacker@example.test",
        "2026-09-23T00:00:00.000Z",
      ),
    ).resolves.toEqual([]);
  });
});
