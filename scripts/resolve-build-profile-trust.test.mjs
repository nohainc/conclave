import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { resolveBuildProfileTrust } from "./resolve-build-profile-trust.mjs";

it("preserves hosted development trust across ordinary rebuilds and isolates signed builds", () => {
  const root = mkdtempSync(join(tmpdir(), "profile-build-trust-"));
  const keys = { development: { key: Buffer.alloc(32, 1).toString("base64") } };
  try {
    expect(() => resolveBuildProfileTrust(root, {})).toThrow("Supply");
    mkdirSync(join(root, ".development"));
    writeFileSync(
      join(root, ".development/hosted-profile-trust.json"),
      JSON.stringify(keys),
    );
    expect(JSON.parse(resolveBuildProfileTrust(root, {}))).toEqual(keys);
    expect(() =>
      resolveBuildProfileTrust(root, {
        CONCLAVE_MACOS_SIGN_IDENTITY: "Customer Identity",
      }),
    ).toThrow("explicit");
    const explicit = {
      customer: { key: Buffer.alloc(32, 2).toString("base64") },
    };
    expect(
      JSON.parse(
        resolveBuildProfileTrust(root, {
          CONCLAVE_RELEASE_TRUST_KEYS_JSON: JSON.stringify(explicit),
        }),
      ),
    ).toEqual(explicit);
    expect(() =>
      resolveBuildProfileTrust(root, {
        CONCLAVE_RELEASE_TRUST_KEYS_JSON: "{}",
      }),
    ).toThrow("at least one");
    expect(() =>
      resolveBuildProfileTrust(root, {
        CONCLAVE_RELEASE_TRUST_KEYS_JSON: '{"p":{"k":"invalid"}}',
      }),
    ).toThrow("Ed25519");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
