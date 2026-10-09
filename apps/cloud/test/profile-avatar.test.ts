import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { handleGetAvatar, handleUploadAvatar } from "../src/routes/profile.js";
import type { SecurityEnv } from "../src/routes/http-security.js";

class MemoryAvatarBucket {
  readonly values = new Map<string, { bytes: Uint8Array; mediaType: string }>();

  async put(
    key: string,
    body: ArrayBuffer,
    options: { httpMetadata?: { contentType?: string } },
  ) {
    this.values.set(key, {
      bytes: new Uint8Array(body),
      mediaType:
        options.httpMetadata?.contentType ?? "application/octet-stream",
    });
  }

  async get(key: string) {
    const value = this.values.get(key);
    if (!value) return null;
    return {
      body: new Response(value.bytes.buffer as ArrayBuffer).body!,
      httpMetadata: { contentType: value.mediaType },
      httpEtag: `"${key}"`,
    };
  }

  async delete(key: string) {
    this.values.delete(key);
  }
}

describe("profile avatars", () => {
  let store: ReturnType<typeof sqliteD1>;
  let bucket: MemoryAvatarBucket;
  let env: SecurityEnv;

  beforeEach(() => {
    store = sqliteD1();
    store.sqlite.exec(
      `INSERT INTO users(id,email,display_name,created_at,updated_at)
       VALUES ('a','a@test','Alice','now','now'),('b','b@test','Bob','now','now')`,
    );
    bucket = new MemoryAvatarBucket();
    env = {
      CONCLAVE_DB: store.db,
      CONCLAVE_ENVIRONMENT: "development",
      CONCLAVE_ARTIFACTS: bucket as never,
      TEST_AUTHENTICATION: async (request: Request) => ({
        userId: request.headers.get("authorization") ?? "",
      }),
    } as unknown as SecurityEnv;
  });

  afterEach(() => store.sqlite.close());

  const request = (
    userId: string,
    init: RequestInit = {},
    url = "https://conclave.test/api/profile/avatar",
  ) =>
    (() => {
      const headers = new Headers(init.headers);
      headers.set("authorization", userId);
      return new Request(url, { ...init, headers });
    })();

  it("stores the avatar privately and serves it to the owner", async () => {
    const upload = await handleUploadAvatar(
      request("a", {
        method: "PUT",
        headers: { "content-type": "image/png" },
        body: new Uint8Array([1, 2, 3]),
      }),
      env,
    );
    expect(upload.status).toBe(200);
    const payload = (await upload.json()) as { avatarUrl: string };
    expect(payload.avatarUrl).toMatch(
      /^https:\/\/conclave\.test\/api\/users\/a\/avatar\?v=[0-9a-f-]+$/,
    );
    expect(
      store.sqlite.prepare("SELECT avatar_url FROM users WHERE id='a'").get(),
    ).toMatchObject({ avatar_url: expect.stringMatching(/^r2:\/\//) });

    const avatar = await handleGetAvatar(
      request("a", {}, payload.avatarUrl),
      env,
      "a",
    );
    expect(avatar.status).toBe(200);
    expect(avatar.headers.get("content-type")).toBe("image/png");
    expect([...new Uint8Array(await avatar.arrayBuffer())]).toEqual([1, 2, 3]);
  });

  it("does not expose avatars to unrelated users", async () => {
    await handleUploadAvatar(
      request("a", {
        method: "PUT",
        headers: { "content-type": "image/jpeg" },
        body: new Uint8Array([4, 5]),
      }),
      env,
    );
    await expect(
      handleGetAvatar(
        request("b", {}, "https://conclave.test/api/users/a/avatar"),
        env,
        "a",
      ),
    ).rejects.toMatchObject({ status: 404 });

    store.sqlite.exec(
      "INSERT INTO people_relationships(user_low_id,user_high_id,established_at) VALUES ('a','b','now')",
    );
    const shared = await handleGetAvatar(
      request("b", {}, "https://conclave.test/api/users/a/avatar"),
      env,
      "a",
    );
    expect(shared.status).toBe(200);
  });
});
