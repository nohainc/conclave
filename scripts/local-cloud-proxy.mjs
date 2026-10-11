const upstream = "https://app.conclaveax.com";
const localPrefix = "conclave-dev-";

const legacyWorkHistoryPath =
  /^\/api\/threads\/workstream-[^/]+\/work-requests$/;

export function upstreamCookie(value) {
  return value.replace(/(^|;\s*)conclave-dev-(Secure|Host)-/g, "$1__$2-");
}

export function localCookie(value) {
  return value
    .replace(/^__(Secure|Host)-/, `${localPrefix}$1-`)
    .replace(/;\s*Secure\b/gi, "")
    .replace(/;\s*Domain=[^;]*/gi, "")
    .replace(/;\s*SameSite=None\b/gi, "; SameSite=Lax");
}

export async function proxyCloud(request, send = fetch) {
  const incoming = new URL(request.url);
  if (
    !incoming.pathname.startsWith("/api/") &&
    incoming.pathname !== "/health"
  ) {
    return new Response(
      "Local API gateway: use the AX frontend on port 3000.",
      { status: 404 },
    );
  }
  // A browser tab can retain a workstream-* identifier from an older AX
  // build. Keep the local production proxy from forwarding that retired scope
  // to Cloud, where it correctly has no matching thread and returns 404.
  // The response is deliberately empty: this identifier carries no current
  // user data and must not become a discovery mechanism.
  if (
    request.method === "GET" &&
    legacyWorkHistoryPath.test(incoming.pathname)
  ) {
    return new Response(
      JSON.stringify({ workRequests: [], nextCursor: null }),
      {
        status: 200,
        headers: {
          "cache-control": "no-store",
          "content-type": "application/json; charset=utf-8",
        },
      },
    );
  }
  const target = new URL(incoming.pathname + incoming.search, upstream);
  const headers = new Headers(request.headers);
  headers.delete("host");
  if (headers.has("cookie"))
    headers.set("cookie", upstreamCookie(headers.get("cookie")));
  const response = await send(
    new globalThis.Request(target, {
      method: request.method,
      headers,
      body: ["GET", "HEAD"].includes(request.method) ? undefined : request.body,
      duplex: "half",
      redirect: "manual",
    }),
  );
  // Preserve the upstream WebSocket upgrade and live event connection.
  if (response.status === 101) return response;
  const output = new Headers(response.headers);
  output.delete("set-cookie");
  for (const cookie of response.headers.getSetCookie())
    output.append("set-cookie", localCookie(cookie));
  output.set("cache-control", "no-store");
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: output,
  });
}

export default { fetch: (request) => proxyCloud(request) };
