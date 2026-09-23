import { describe, expect, it } from "vitest";
import {
  IdentityService,
  type AuthenticatedIdentity,
} from "../src/auth/index.js";

describe("IdentityService", () => {
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
