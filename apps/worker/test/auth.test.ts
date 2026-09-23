import { describe, expect, it } from "vitest";
import {
  buildBetterAuthOptions,
  IdentityService,
  safeAuthReturnTo,
  type AuthenticatedIdentity,
} from "../src/auth/index.js";

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
      trustedProviders: [],
      allowDifferentEmails: false,
    });
    expect(options.session?.modelName).toBe("auth_sessions");
    expect(options.verification?.modelName).toBe("auth_verifications");
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
});
