interface Env {
  ASSETS: {
    fetch(request: Request): Promise<Response>;
  };
}

const CANONICAL_HOST = "conclaveax.com";
const WWW_HOST = "www.conclaveax.com";

function isFingerprintAsset(pathname: string): boolean {
  return (
    pathname.startsWith("/_astro/") || /\.[a-f0-9]{8,}\.[^/]+$/i.test(pathname)
  );
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.hostname === WWW_HOST) {
      url.hostname = CANONICAL_HOST;
      return Response.redirect(url.toString(), 308);
    }

    const response = await env.ASSETS.fetch(request);
    const headers = new Headers(response.headers);
    if (isFingerprintAsset(url.pathname)) {
      headers.set("cache-control", "public, max-age=31536000, immutable");
    } else if (url.pathname.endsWith(".html") || url.pathname === "/") {
      headers.set("cache-control", "public, max-age=0, must-revalidate");
    }

    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  },
} satisfies {
  fetch(request: Request, env: Env): Promise<Response>;
};
