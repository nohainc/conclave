import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { validateEmailDeploymentConfig } from "./verify-email-config.mjs";

describe("email deployment configuration", () => {
  it("keeps production and development sender configuration safe", () => {
    expect(validateEmailDeploymentConfig(process.cwd())).toEqual([]);
  });

  it("rejects a retired sender and a missing binding", () => {
    const root = mkdtempSync(join(tmpdir(), "conclave-email-config-"));
    try {
      mkdirSync(join(root, "infra/cloudflare"), { recursive: true });
      mkdirSync(join(root, "apps/cloud"), { recursive: true });
      mkdirSync(join(root, "apps/cloud/src/auth"), { recursive: true });
      writeFileSync(
        join(root, "infra/cloudflare/app.wrangler.jsonc"),
        JSON.stringify({
          vars: {
            CONCLAVE_ENVIRONMENT: "production",
            CONCLAVE_EMAIL_FROM: "auth@auth.earthuc.com",
            CONCLAVE_EMAIL_FALLBACK_FROM: "vitalii@nohainc.com",
            CONCLAVE_EMAIL_FROM_NAME: "Conclave AX",
          },
          send_email: [],
        }),
      );
      writeFileSync(
        join(root, "apps/cloud/wrangler.jsonc"),
        JSON.stringify({
          vars: { CONCLAVE_ENVIRONMENT: "development" },
          send_email: [{ name: "CONCLAVE_EMAIL" }],
        }),
      );
      writeFileSync(
        join(root, "apps/cloud/src/auth/better-auth.ts"),
        'const legacy = "auth@auth.earthuc.com";',
      );

      expect(validateEmailDeploymentConfig(root)).toEqual(
        expect.arrayContaining([
          "production: retired sender is configured",
          "production: CONCLAVE_EMAIL send_email binding is missing",
          "production: retired sender appears in Wrangler configuration",
          "apps/cloud/src/auth/better-auth.ts: retired sender appears in active email code",
        ]),
      );
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});
