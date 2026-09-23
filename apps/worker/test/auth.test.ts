import { describe, expect, it } from "vitest";
import {
  buildBetterAuthOptions,
  IdentityService,
  type AuthenticatedIdentity,
} from "../src/auth/index.js";

describe("IdentityService", () => {
  it("configures Better Auth against the clean Conclave core tables", () => {
    const options = buildBetterAuthOptions({
      CONCLAVE_DB: {} as D1Database,
      CONCLAVE_ENVIRONMENT: "development",
      BETTER_AUTH_SECRET: "a-secure-development-secret-that-is-long-enough",
    });

    expect(options.user?.modelName).toBe("users");
    expect(options.user?.fields).toMatchObject({
      name: "display_name",
      emailVerified: "email_verified",
      image: "avatar_url",
    });
    expect(options.account?.modelName).toBe("auth_accounts");
    expect(options.session?.modelName).toBe("auth_sessions");
    expect(options.verification?.modelName).toBe("auth_verifications");
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
