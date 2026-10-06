import { expect, it } from "vitest";
import {
  localCookie,
  proxyCloud,
  upstreamCookie,
} from "./local-cloud-proxy.mjs";

it("forwards authentication, raw bodies and queries to the fixed hosted Cloud", async () => {
  const source = JSON.stringify({
    email: "test@example.com",
    password: "fixture-only",
  });
  const result = await proxyCloud(
    new globalThis.Request(
      "http://localhost:8787/api/auth/sign-in/email?test=1",
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          origin: "http://localhost:3000",
          cookie: "conclave-dev-Secure-better-auth.session_token=fixture",
        },
        body: source,
      },
    ),
    async (request) => {
      expect(request.url).toBe(
        "https://app.conclaveax.com/api/auth/sign-in/email?test=1",
      );
      expect(await request.text()).toBe(source);
      expect(request.headers.get("origin")).toBe("http://localhost:3000");
      expect(request.headers.get("cookie")).toBe(
        "__Secure-better-auth.session_token=fixture",
      );
      return new Response("ok", {
        headers: {
          "set-cookie":
            "__Secure-better-auth.session_token=fixture; Secure; Domain=app.conclaveax.com; SameSite=None; HttpOnly; Path=/",
        },
      });
    },
  );
  expect(result.headers.get("set-cookie")).toBe(
    "conclave-dev-Secure-better-auth.session_token=fixture; SameSite=Lax; HttpOnly; Path=/",
  );
  expect(result.headers.get("cache-control")).toBe("no-store");
});
it("preserves errors and WebSocket upgrades", async () => {
  const upgrade = { status: 101, webSocket: {} };
  expect(
    await proxyCloud(
      new globalThis.Request("http://localhost:8787/api/realtime"),
      async () => upgrade,
    ),
  ).toBe(upgrade);
  const error = await proxyCloud(
    new globalThis.Request("http://localhost:8787/api/session"),
    async () => new Response("unauthorized", { status: 401 }),
  );
  expect(error.status).toBe(401);
  expect(await error.text()).toBe("unauthorized");
});
it("maps cookie names reversibly and rejects non-API paths", async () => {
  expect(upstreamCookie("a=1; conclave-dev-Host-auth=value")).toBe(
    "a=1; __Host-auth=value",
  );
  expect(localCookie("__Host-auth=value; Secure; Path=/; HttpOnly")).toBe(
    "conclave-dev-Host-auth=value; Path=/; HttpOnly",
  );
  expect(
    (
      await proxyCloud(
        new globalThis.Request("http://localhost:8787/not-api"),
        () => {
          throw new Error("unexpected network");
        },
      )
    ).status,
  ).toBe(404);
});
