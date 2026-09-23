interface Env {
  ASSETS: {
    fetch(request: Request): Promise<Response>;
  };
}

const CANONICAL_HOST = "conclaveax.com";
const WWW_HOST = "www.conclaveax.com";
const SECURITY_HEADERS = {
  "content-security-policy":
    "default-src 'self'; base-uri 'self'; connect-src 'self'; font-src 'self'; form-action 'self'; frame-ancestors 'none'; frame-src 'none'; img-src 'self' data:; object-src 'none'; script-src 'self'; style-src 'self'; upgrade-insecure-requests",
  "permissions-policy":
    "camera=(), geolocation=(), microphone=(), payment=(), usb=()",
  "referrer-policy": "strict-origin-when-cross-origin",
  "strict-transport-security": "max-age=31536000; includeSubDomains",
  "x-content-type-options": "nosniff",
  "x-frame-options": "DENY",
};

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
    headers.delete("set-cookie");
    Object.entries(SECURITY_HEADERS).forEach(([name, value]) =>
      headers.set(name, value),
    );
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
