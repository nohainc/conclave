import { describe, expect, it } from "vitest";
import worker from "../src/worker";

function environment() {
  return {
    ASSETS: {
      fetch: async () =>
        new Response("site", {
          headers: { "content-type": "text/html" },
        }),
    },
  };
}

describe("public site Worker", () => {
  it("redirects www to the canonical apex domain", async () => {
    const response = await worker.fetch(
      new Request("https://www.conclaveax.com/how-it-works/?source=www"),
      environment(),
    );

    expect(response.status).toBe(308);
    expect(response.headers.get("location")).toBe(
      "https://conclaveax.com/how-it-works/?source=www",
    );
  });

  it("uses revalidation for HTML responses", async () => {
    const response = await worker.fetch(
      new Request("https://conclaveax.com/"),
      environment(),
    );

    expect(response.headers.get("cache-control")).toBe(
      "public, max-age=0, must-revalidate",
    );
  });

  it("marks fingerprinted assets immutable", async () => {
    const response = await worker.fetch(
      new Request("https://conclaveax.com/_astro/site.12345678.js"),
      environment(),
    );

    expect(response.headers.get("cache-control")).toBe(
      "public, max-age=31536000, immutable",
    );
  });
});
