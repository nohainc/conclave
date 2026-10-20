import { describe, expect, it, vi } from "vitest";
import {
  handleBetterAuthRequest,
  handleEmailChangeConfirm,
  handleEmailChangeSendCode,
  handleEmailChangeVerifyNew,
} from "../src/auth/better-auth.js";

type Row = { id: string; identifier: string; value: string; expires_at: string };

function createMemoryDb(users: Record<string, string>) {
  const verifications = new Map<string, Row>();
  const statement = (query: string) => {
    let bound: unknown[] = [];
    const self = {
      bind(...values: unknown[]) {
        bound = values;
        return self;
      },
      async first<T>() {
        if (query.includes("FROM users WHERE lower(email)")) {
          const [email, excluded] = bound as [string, string];
          const match = Object.entries(users).find(
            ([id, value]) => value === email && id !== excluded,
          );
          return (match ? { id: match[0] } : null) as T | null;
        }
        if (query.includes("FROM auth_verifications")) {
          return (verifications.get(String(bound[0])) ?? null) as T | null;
        }
        return null;
      },
      async run() {
        if (query.includes("DELETE FROM auth_verifications WHERE identifier")) {
          verifications.delete(String(bound[0]));
        } else if (query.includes("DELETE FROM auth_verifications WHERE id")) {
          for (const [key, row] of verifications) {
            if (row.id === bound[0]) verifications.delete(key);
          }
        } else if (query.includes("INSERT INTO auth_verifications")) {
          const [id, identifier, value, expires_at] = bound as string[];
          verifications.set(identifier!, {
            id: id!,
            identifier: identifier!,
            value: value!,
            expires_at: expires_at!,
          });
        } else if (query.includes("UPDATE auth_verifications")) {
          const [value, , id] = bound as string[];
          for (const [key, row] of verifications) {
            if (row.id === id) verifications.set(key, { ...row, value: value! });
          }
        } else if (query.includes("UPDATE users SET email")) {
          const [email, , id] = bound as string[];
          users[id!] = email!;
        }
        return { success: true };
      },
    };
    return self;
  };
  const db = {
    prepare: statement,
    async batch(statements: Array<{ run(): Promise<unknown> }>) {
      for (const item of statements) await item.run();
      return [];
    },
  } as unknown as D1Database;
  return { db, users, verifications };
}

function post(path: string, body: unknown): Request {
  return new Request(`https://app.conclaveax.com/api/auth/${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

function sentCode(send: ReturnType<typeof vi.fn>, index: number): string {
  const message = send.mock.calls[index]?.[0] as { subject: string };
  return message.subject.slice(0, 6);
}

describe("two-step email change", () => {
  const user = { id: "user-1", email: "old@example.com", name: "Person" };

  function setup(extraUsers: Record<string, string> = {}) {
    const memory = createMemoryDb({ "user-1": user.email, ...extraUsers });
    const send = vi.fn(async (_message: unknown) => ({ messageId: "m" }));
    const env = {
      CONCLAVE_DB: memory.db,
      CONCLAVE_ENVIRONMENT: "production",
      BETTER_AUTH_SECRET: "a-secure-production-secret-that-is-long-enough",
      BETTER_AUTH_URL: "https://app.conclaveax.com",
      CONCLAVE_EMAIL: { send },
    };
    return { ...memory, send, env };
  }

  it("requires codes from the new and then the current address", async () => {
    const { env, send, users, verifications } = setup();

    const started = await handleEmailChangeSendCode(
      post("change-email/send-code", { newEmail: "New@Example.com" }),
      env,
      user,
    );
    expect(started.status).toBe(200);
    await expect(started.json()).resolves.toMatchObject({
      stage: "new",
      email: "new@example.com",
    });
    expect((send.mock.calls[0]?.[0] as { to: string }).to).toBe(
      "new@example.com",
    );
    expect((send.mock.calls[0]?.[0] as { text: string }).text).toContain(
      "confirm your email change",
    );

    // The current-address step cannot be completed before the new one.
    const early = await handleEmailChangeConfirm(
      post("change-email/confirm", { code: sentCode(send, 0) }),
      env,
      user,
    );
    expect(early.status).toBe(400);
    expect(users["user-1"]).toBe("old@example.com");

    await handleEmailChangeSendCode(
      post("change-email/send-code", { newEmail: "new@example.com" }),
      env,
      user,
    );
    const verified = await handleEmailChangeVerifyNew(
      post("change-email/verify-new", { code: sentCode(send, 1) }),
      env,
      user,
    );
    expect(verified.status).toBe(200);
    await expect(verified.json()).resolves.toMatchObject({
      stage: "current",
      email: "old@example.com",
    });
    expect((send.mock.calls[2]?.[0] as { to: string }).to).toBe(
      "old@example.com",
    );
    expect(users["user-1"]).toBe("old@example.com");

    const confirmed = await handleEmailChangeConfirm(
      post("change-email/confirm", { code: sentCode(send, 2) }),
      env,
      user,
    );
    expect(confirmed.status).toBe(200);
    await expect(confirmed.json()).resolves.toEqual({
      status: true,
      email: "new@example.com",
    });
    expect(users["user-1"]).toBe("new@example.com");
    expect(verifications.size).toBe(0);
  });

  it("rejects wrong codes and addresses used by another account", async () => {
    const { env, send } = setup({ "user-2": "taken@example.com" });

    const taken = await handleEmailChangeSendCode(
      post("change-email/send-code", { newEmail: "taken@example.com" }),
      env,
      user,
    );
    expect(taken.status).toBe(409);
    const same = await handleEmailChangeSendCode(
      post("change-email/send-code", { newEmail: "old@example.com" }),
      env,
      user,
    );
    expect(same.status).toBe(400);

    await handleEmailChangeSendCode(
      post("change-email/send-code", { newEmail: "new@example.com" }),
      env,
      user,
    );
    const wrong = sentCode(send, 0) === "000000" ? "111111" : "000000";
    const rejected = await handleEmailChangeVerifyNew(
      post("change-email/verify-new", { code: wrong }),
      env,
      user,
    );
    expect(rejected.status).toBe(400);
    await expect(rejected.json()).resolves.toMatchObject({
      code: "INVALID_OTP",
    });
  });

  it("retires Better Auth's link-based change-email endpoint", async () => {
    const { env } = setup();
    const response = await handleBetterAuthRequest(
      post("change-email", { newEmail: "new@example.com" }),
      env,
    );
    expect(response.status).toBe(410);
  });

  it("rejects unauthenticated email change and account deletion", async () => {
    const { env } = setup();
    for (const path of ["change-email/send-code", "delete-user"]) {
      const response = await handleBetterAuthRequest(
        post(path, { newEmail: "new@example.com", confirmEmail: "x" }),
        env,
      );
      expect(response.status).toBe(401);
    }
  });
});
