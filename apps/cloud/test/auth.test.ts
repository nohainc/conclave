import { describe, expect, it, vi } from "vitest";
import {
  buildBetterAuthOptions,
  configuredAppOrigin,
  copySetCookieHeaders,
  handleBetterAuthRequest,
  IdentityService,
  isSocialProviderConfigured,
  provisionConclaveUser,
  safeAuthReturnTo,
  type AuthenticatedIdentity,
} from "../src/auth/index.js";
import { requireSameOriginForCookieMutation } from "../src/routes/handlers.js";

describe("IdentityService", () => {
  it("fails closed with a diagnostic response when Better Auth is not configured", async () => {
    const response = await handleBetterAuthRequest(
      new Request("https://app.conclave.test/api/auth/sign-in/github"),
      {
        CONCLAVE_DB: {} as D1Database,
        CONCLAVE_ENVIRONMENT: "production",
      },
    );

    expect(response.status).toBe(503);
    await expect(response.json()).resolves.toEqual({
      error: "Authentication is not configured on this deployment",
      code: "auth_not_configured",
    });
  });

  it("preserves all OAuth state cookies when redirecting to a provider", () => {
    const source = new Headers();
    source.append("set-cookie", "oauth_state=one; Path=/; HttpOnly");
    source.append("set-cookie", "oauth_nonce=two; Path=/; HttpOnly");
    const target = new Headers();

    copySetCookieHeaders(source, target);

    expect(target.get("set-cookie")).toContain("oauth_state=one");
    expect(target.get("set-cookie")).toContain("oauth_nonce=two");
  });

  it("keeps social login return paths same-origin", () => {
    const request = new Request(
      "https://app.conclave.test/api/auth/sign-in/github",
    );
    expect(safeAuthReturnTo(request, "/spaces/p-1/threads/ws-1")).toBe(
      "/spaces/p-1/threads/ws-1",
    );
    expect(safeAuthReturnTo(request, "https://evil.example/steal")).toBe("/");
    expect(safeAuthReturnTo(request, "/api/auth/sign-out")).toBe("/");
  });

  it("returns to the configured app origin and still rejects other origins", () => {
    // Local development: the API is on :8787 and the Flutter app on :3000.
    const request = new Request(
      "http://localhost:8787/api/auth/sign-in/google",
    );
    const app = "http://localhost:3000";
    expect(
      safeAuthReturnTo(request, "http://localhost:3000/spaces?x=1", app),
    ).toBe("http://localhost:3000/spaces?x=1");
    expect(safeAuthReturnTo(request, "/spaces", app)).toBe(
      "http://localhost:3000/spaces",
    );
    expect(safeAuthReturnTo(request, null, app)).toBe("http://localhost:3000/");
    expect(safeAuthReturnTo(request, "http://localhost:8787/spaces", app)).toBe(
      "/spaces",
    );
    expect(safeAuthReturnTo(request, "https://evil.example/x", app)).toBe("/");
    expect(safeAuthReturnTo(request, "http://localhost:3001/x", app)).toBe("/");
    expect(
      safeAuthReturnTo(request, "http://localhost:3000/api/auth/x", app),
    ).toBe("/");
    // Without an app origin, behavior is unchanged: same-origin paths only.
    expect(safeAuthReturnTo(request, "http://localhost:3000/spaces")).toBe("/");
  });

  it("reads the app origin and provider credentials from configuration", () => {
    expect(
      configuredAppOrigin({ CONCLAVE_APP_URL: "http://localhost:3000/x" }),
    ).toBe("http://localhost:3000");
    expect(
      configuredAppOrigin({ CONCLAVE_APP_URL: "not a url" }),
    ).toBeUndefined();
    expect(configuredAppOrigin({})).toBeUndefined();
    const onlyId = { CONCLAVE_AUTH_GOOGLE_CLIENT_ID: "id" };
    expect(isSocialProviderConfigured(onlyId, "google")).toBe(false);
    expect(
      isSocialProviderConfigured(
        { ...onlyId, CONCLAVE_AUTH_GOOGLE_CLIENT_SECRET: "secret" },
        "google",
      ),
    ).toBe(true);
    expect(isSocialProviderConfigured(onlyId, "github")).toBe(false);
  });

  it.each(["google", "github"])(
    "sends an unconfigured %s sign-in to the app login page with a clear error",
    async (provider) => {
      const response = await handleBetterAuthRequest(
        new Request(
          `http://localhost:8787/api/auth/sign-in/${provider}?returnTo=http%3A%2F%2Flocalhost%3A3000%2Fspaces`,
        ),
        {
          // Minimal D1 surface so Better Auth initializes without a real database.
          CONCLAVE_DB: {
            prepare: () => ({}),
            batch: async () => [],
            exec: async () => ({}),
            dump: async () => new ArrayBuffer(0),
          } as unknown as D1Database,
          CONCLAVE_ENVIRONMENT: "development",
          BETTER_AUTH_SECRET: "a-secure-development-secret-that-is-long-enough",
          BETTER_AUTH_URL: "http://localhost:8787",
          CONCLAVE_APP_URL: "http://localhost:3000",
        },
      );
      expect(response.status).toBe(302);
      const location = new URL(response.headers.get("location") as string);
      expect(location.origin).toBe("http://localhost:3000");
      expect(location.pathname).toBe("/login");
      expect(location.searchParams.get("error")).toBe(
        "provider_not_configured",
      );
      expect(location.searchParams.get("returnTo")).toBe("/spaces");
    },
  );

  it("includes the app origin in Better Auth trusted origins", () => {
    const options = buildBetterAuthOptions({
      CONCLAVE_DB: {} as D1Database,
      CONCLAVE_ENVIRONMENT: "development",
      BETTER_AUTH_SECRET: "a-secure-development-secret-that-is-long-enough",
      CONCLAVE_APP_URL: "http://localhost:4000",
      CONCLAVE_AUTH_GOOGLE_CLIENT_ID: "google-client-id",
      CONCLAVE_AUTH_GOOGLE_CLIENT_SECRET: "google-client-secret",
    });
    expect(options.trustedOrigins).toContain("http://localhost:4000");
    expect(options.socialProviders.google).toMatchObject({
      clientId: "google-client-id",
      scope: ["email", "profile"],
    });
  });

  it("configures Better Auth against the clean Conclave core tables", () => {
    const options = buildBetterAuthOptions({
      CONCLAVE_DB: {} as D1Database,
      CONCLAVE_ENVIRONMENT: "development",
      BETTER_AUTH_SECRET: "a-secure-development-secret-that-is-long-enough",
      CONCLAVE_AUTH_GITHUB_CLIENT_ID: "github-client-id",
      CONCLAVE_AUTH_GITHUB_CLIENT_SECRET: "github-client-secret",
      CONCLAVE_AUTH_GOOGLE_CLIENT_ID: "google-client-id",
      CONCLAVE_AUTH_GOOGLE_CLIENT_SECRET: "google-client-secret",
    });

    expect(options.user?.modelName).toBe("users");
    expect(options.user?.fields).toMatchObject({
      name: "display_name",
      emailVerified: "email_verified",
      image: "avatar_url",
    });
    expect(options.user?.changeEmail).toMatchObject({
      enabled: true,
    });
    expect(options.user?.deleteUser).toMatchObject({
      enabled: true,
    });
    expect(options.user?.changeEmail?.sendChangeEmailConfirmation).toEqual(
      expect.any(Function),
    );
    expect(options.account?.modelName).toBe("auth_accounts");
    expect(options.account?.encryptOAuthTokens).toBe(true);
    expect(options.account?.accountLinking).toMatchObject({
      enabled: true,
      disableImplicitLinking: true,
      trustedProviders: ["github", "google"],
      allowDifferentEmails: false,
    });
    expect(options.emailAndPassword).toMatchObject({
      enabled: true,
      disableSignUp: false,
      minPasswordLength: 8,
      maxPasswordLength: 128,
      autoSignIn: true,
      revokeSessionsOnPasswordReset: true,
      resetPasswordTokenExpiresIn: 3600,
    });
    expect(options.emailVerification).toMatchObject({
      expiresIn: 3600,
      sendOnSignUp: true,
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

  it("uses the centralized sender for verification, reset, and email change messages", async () => {
    const send = vi.fn(async (_message: unknown) => ({
      messageId: "message-1",
    }));
    const options = buildBetterAuthOptions({
      CONCLAVE_DB: {} as D1Database,
      CONCLAVE_ENVIRONMENT: "production",
      BETTER_AUTH_SECRET: "a-secure-production-secret-that-is-long-enough",
      BETTER_AUTH_URL: "https://app.conclave.test",
      CONCLAVE_EMAIL: { send },
    });
    const user = { email: "person@example.com", name: "Person" };

    await options.emailVerification?.sendVerificationEmail?.({
      user,
      url: "https://app.conclave.test/verify",
    });
    await options.emailAndPassword?.sendResetPassword?.({
      user,
      url: "https://app.conclave.test/reset",
    });
    await options.user?.changeEmail?.sendChangeEmailConfirmation?.({
      user,
      newEmail: "new@example.com",
      url: "https://app.conclave.test/change",
    });

    expect(send).toHaveBeenCalledTimes(3);
    const messages = send.mock.calls.map(
      ([message]) =>
        message as {
          to: string;
          subject: string;
          text?: string;
          html?: string;
          from: { email: string; name: string };
        },
    );
    for (const message of messages) {
      expect(message).toMatchObject({
        from: { email: "conclave@conclaveax.com", name: "Conclave AX" },
        to: "person@example.com",
      });
    }
    expect(messages.map((message) => message.subject)).toEqual([
      "Verify your Conclave AX email address",
      "Reset your Conclave AX password",
      "Confirm your Conclave AX email change",
    ]);
    expect(messages[0]?.text).toContain("https://app.conclave.test/verify");
    expect(messages[0]?.text).toContain("This link is valid for 60 minutes.");
    expect(messages[1]?.text).toContain("https://app.conclave.test/reset");
    expect(messages[2]?.text).toContain("https://app.conclave.test/change");

    await options.databaseHooks?.user?.create?.after?.({
      id: "user-1",
      email: "person@example.com",
      name: "Person",
    });
    expect(send).toHaveBeenCalledTimes(4);
    const welcomeMessage = send.mock.calls[3]?.[0] as {
      to: string;
      subject: string;
      text?: string;
      from: { email: string; name: string };
    };
    expect(welcomeMessage).toMatchObject({
      from: { email: "conclave@conclaveax.com", name: "Conclave AX" },
      to: "person@example.com",
      subject: "Welcome to Conclave AX — your account is ready",
    });
    expect(welcomeMessage.text).toContain("Congratulations");
    expect(welcomeMessage.text).toContain("https://app.conclave.test");
  });

  it("sends the account-deleted template to the removed account's email", async () => {
    const send = vi.fn(async (_message: unknown) => ({ messageId: "deleted-1" }));
    const options = buildBetterAuthOptions({
      CONCLAVE_DB: {} as D1Database,
      CONCLAVE_ENVIRONMENT: "production",
      BETTER_AUTH_SECRET: "a-secure-production-secret-that-is-long-enough",
      CONCLAVE_EMAIL: { send },
    });
    expect(options.user.deleteUser.afterDelete).toEqual(expect.any(Function));
    await options.user.deleteUser.afterDelete({
      email: "removed@example.com",
      name: "Ada",
    });
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0]?.[0]).toMatchObject({
      to: "removed@example.com",
      subject: "Your Conclave AX account was deleted",
      from: { email: "conclave@conclaveax.com", name: "Conclave AX" },
      text: expect.stringContaining("Hi Ada"),
      html: expect.stringContaining("Account deleted"),
    });
  });

  it("does not fail completed account deletion when notification delivery fails", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      const options = buildBetterAuthOptions({
        CONCLAVE_DB: {} as D1Database,
        CONCLAVE_ENVIRONMENT: "production",
        BETTER_AUTH_SECRET: "a-secure-production-secret-that-is-long-enough",
        CONCLAVE_EMAIL: {
          send: vi.fn(async () => {
            throw new Error("private provider response");
          }),
        },
      });
      await expect(options.user.deleteUser.afterDelete({
        email: "removed@example.com",
        name: "Ada",
      })).resolves.toBeUndefined();
      expect(log).toHaveBeenCalledWith(
        "auth.account_deleted_email.failed",
        expect.objectContaining({ status: expect.any(String) }),
      );
      expect(JSON.stringify(log.mock.calls)).not.toContain("removed@example.com");
      expect(JSON.stringify(log.mock.calls)).not.toContain("private provider response");
    } finally {
      log.mockRestore();
    }
  });

  describe("verification email failures", () => {
    const failingEnv = () =>
      buildBetterAuthOptions({
        CONCLAVE_DB: {} as D1Database,
        CONCLAVE_ENVIRONMENT: "production",
        BETTER_AUTH_SECRET: "a-secure-production-secret-that-is-long-enough",
        BETTER_AUTH_URL: "https://app.conclave.test",
        CONCLAVE_EMAIL: {
          send: vi.fn(async () => {
            throw Object.assign(new Error("down"), { status: 503 });
          }),
        },
      });
    const payload = {
      user: { email: "person@example.com", name: "Person" },
      url: "https://app.conclave.test/verify",
    };

    it("does not fail sign-up after the account is created", async () => {
      const error = vi.spyOn(console, "error").mockImplementation(() => {});
      const signUp = new Request(
        "https://app.conclave.test/api/auth/sign-up/email",
        { method: "POST" },
      );
      await expect(
        failingEnv().emailVerification?.sendVerificationEmail?.(
          payload,
          signUp,
        ),
      ).resolves.toBeUndefined();
      expect(error).toHaveBeenCalledWith(
        "auth.verification_email.signup_failed",
        { status: "service_unavailable", providerCode: undefined },
      );
      error.mockRestore();
    });

    it("still reports failures to an explicit resend request", async () => {
      const resend = new Request(
        "https://app.conclave.test/api/auth/send-verification-email",
        { method: "POST" },
      );
      await expect(
        failingEnv().emailVerification?.sendVerificationEmail?.(
          payload,
          resend,
        ),
      ).rejects.toMatchObject({ status: "service_unavailable" });
    });
  });

  it("uses the fallback once when the primary sender is rejected", async () => {
    const send = vi
      .fn(async (_message: unknown) => ({ messageId: "message-1" }))
      .mockRejectedValueOnce({ code: "E_SENDER_NOT_VERIFIED" })
      .mockResolvedValueOnce({ messageId: "message-2" });
    const options = buildBetterAuthOptions({
      CONCLAVE_DB: {} as D1Database,
      CONCLAVE_ENVIRONMENT: "production",
      BETTER_AUTH_SECRET: "a-secure-production-secret-that-is-long-enough",
      BETTER_AUTH_URL: "https://app.conclave.test",
      CONCLAVE_EMAIL: { send },
    });

    await options.emailAndPassword?.sendResetPassword?.({
      user: { email: "person@example.com", name: "Person" },
      url: "https://app.conclave.test/reset",
    });

    expect(send).toHaveBeenCalledTimes(2);
    expect(send.mock.calls[1]?.[0]).toMatchObject({
      from: { email: "vitalii@conclaveax.com", name: "Conclave AX" },
    });
  });

  it("does not submit authentication mail when template rendering fails", async () => {
    const send = vi.fn(async (_message: unknown) => ({
      messageId: "message-1",
    }));
    const options = buildBetterAuthOptions({
      CONCLAVE_DB: {} as D1Database,
      CONCLAVE_ENVIRONMENT: "production",
      BETTER_AUTH_SECRET: "a-secure-production-secret-that-is-long-enough",
      BETTER_AUTH_URL: "https://app.conclave.test",
      CONCLAVE_EMAIL: { send },
    });

    await expect(
      options.emailVerification?.sendVerificationEmail?.({
        user: { email: "person@example.com", name: "Person" },
        url: "javascript:alert(1)",
      }),
    ).rejects.toThrow("absolute http(s) URL");
    expect(send).not.toHaveBeenCalled();
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
      new Request("https://conclave.test/api/spaces", {
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
      service.resolve(new Request("https://conclave.test/api/spaces"), {
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
        new Request("https://app.conclave.test/api/spaces", {
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
        new Request("https://app.conclave.test/api/spaces", {
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
        new Request("https://app.conclave.test/api/spaces", {
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
      queries.filter((query) => query.includes("INSERT INTO users")),
    ).toHaveLength(2);
    expect(
      queries.some((query) => query.includes("workspace_memberships")),
    ).toBe(false);
  });

  describe("pre-signup email verification code flow", () => {
    function createOtpMemoryDb(existingEmails: string[] = []) {
      const existing = new Set(existingEmails.map((e) => e.toLowerCase()));
      const verifications = new Map<
        string,
        {
          id: string;
          identifier: string;
          value: string;
          expires_at: string;
        }
      >();
      let verifiedEmail: string | undefined;

      const db = {
        prepare(query: string) {
          let bound: unknown[] = [];
          return {
            bind(...values: unknown[]) {
              bound = values;
              return this;
            },
            async first<T>() {
              if (query.includes("FROM users WHERE lower(email)")) {
                const email = String(bound[0] ?? "").toLowerCase();
                return existing.has(email) ? ({ id: "user-1" } as T) : null;
              }
              if (query.includes("FROM auth_verifications")) {
                const identifier = String(bound[0] ?? "");
                return (verifications.get(identifier) ?? null) as T | null;
              }
              return null;
            },
            async run() {
              if (query.includes("DELETE FROM auth_verifications WHERE identifier")) {
                verifications.delete(String(bound[0] ?? ""));
              } else if (query.includes("DELETE FROM auth_verifications WHERE id")) {
                const id = String(bound[0] ?? "");
                for (const [key, row] of verifications.entries()) {
                  if (row.id === id) verifications.delete(key);
                }
              } else if (query.includes("INSERT INTO auth_verifications")) {
                const [id, identifier, value, expires_at] = bound as [
                  string,
                  string,
                  string,
                  string,
                ];
                verifications.set(identifier, {
                  id,
                  identifier,
                  value,
                  expires_at,
                });
              } else if (query.includes("UPDATE auth_verifications")) {
                const [value, _updatedAt, id] = bound as [
                  string,
                  string,
                  string,
                ];
                for (const [key, row] of verifications.entries()) {
                  if (row.id === id) {
                    verifications.set(key, { ...row, value });
                  }
                }
              } else if (query.includes("UPDATE users")) {
                verifiedEmail = String(bound[1] ?? "");
              }
              return { success: true };
            },
          };
        },
      } as unknown as D1Database;

      return { db, verifications, getVerifiedEmail: () => verifiedEmail };
    }

    it("sends a 6-digit verification code and stores it in auth_verifications", async () => {
      const { db, verifications } = createOtpMemoryDb();
      const send = vi.fn(async (_message: unknown) => ({
        messageId: "msg-otp-1",
      }));

      const response = await handleBetterAuthRequest(
        new Request("https://app.conclaveax.com/api/auth/sign-up/send-code", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            email: "newuser@example.com",
            name: "New User",
          }),
        }),
        {
          CONCLAVE_DB: db,
          CONCLAVE_ENVIRONMENT: "production",
          BETTER_AUTH_SECRET: "a-secure-production-secret-that-is-long-enough",
          BETTER_AUTH_URL: "https://app.conclaveax.com",
          CONCLAVE_EMAIL: { send },
        },
      );

      expect(response.status).toBe(200);
      await expect(response.json()).resolves.toEqual({
        sent: true,
        expiresInSeconds: 600,
      });
      expect(send).toHaveBeenCalledOnce();
      const sentMessage = send.mock.calls[0]?.[0] as {
        to: string;
        subject: string;
        text?: string;
        from: { email: string; name: string };
      };
      expect(sentMessage.to).toBe("newuser@example.com");
      expect(sentMessage.from).toEqual({
        email: "conclave@conclaveax.com",
        name: "Conclave AX",
      });
      const stored = verifications.get("signup-otp:newuser@example.com");
      expect(stored).toBeDefined();
      const code = stored?.value.split(":")[0] ?? "";
      expect(code).toMatch(/^\d{6}$/);
      expect(sentMessage.subject).toContain(code);
      expect(sentMessage.text).toContain(code);
    });

    it("rejects sending a verification code when the email is already registered", async () => {
      const { db } = createOtpMemoryDb(["existing@example.com"]);
      const send = vi.fn();

      const response = await handleBetterAuthRequest(
        new Request("https://app.conclaveax.com/api/auth/sign-up/send-code", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            email: "Existing@Example.com",
            name: "Existing",
          }),
        }),
        {
          CONCLAVE_DB: db,
          CONCLAVE_ENVIRONMENT: "production",
          BETTER_AUTH_SECRET: "a-secure-production-secret-that-is-long-enough",
          BETTER_AUTH_URL: "https://app.conclaveax.com",
          CONCLAVE_EMAIL: { send },
        },
      );

      expect(response.status).toBe(409);
      await expect(response.json()).resolves.toMatchObject({
        code: "USER_ALREADY_EXISTS",
      });
      expect(send).not.toHaveBeenCalled();
    });

    it("rejects sign-up with an invalid OTP and tracks attempts", async () => {
      const { db, verifications } = createOtpMemoryDb();
      verifications.set("signup-otp:newuser@example.com", {
        id: "ver-1",
        identifier: "signup-otp:newuser@example.com",
        value: "123456:0",
        expires_at: new Date(Date.now() + 60_000).toISOString(),
      });

      const response = await handleBetterAuthRequest(
        new Request("https://app.conclaveax.com/api/auth/sign-up/email", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            name: "New User",
            email: "newuser@example.com",
            password: "strong-password-123",
            otp: "000000",
          }),
        }),
        {
          CONCLAVE_DB: db,
          CONCLAVE_ENVIRONMENT: "production",
          BETTER_AUTH_SECRET: "a-secure-production-secret-that-is-long-enough",
          BETTER_AUTH_URL: "https://app.conclaveax.com",
        },
      );

      expect(response.status).toBe(400);
      await expect(response.json()).resolves.toMatchObject({
        code: "INVALID_OTP",
      });
      expect(
        verifications.get("signup-otp:newuser@example.com")?.value,
      ).toBe("123456:1");
    });
  });
});
