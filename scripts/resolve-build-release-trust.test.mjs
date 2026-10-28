import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { resolveBuildReleaseTrust } from "./resolve-build-release-trust.mjs";

it("resolves hosted or explicit application-release trust roots", () => {
  const root = mkdtempSync(join(tmpdir(), "release-build-trust-"));
  const keys = { development: { key: Buffer.alloc(32, 1).toString("base64") } };
  try {
    expect(() => resolveBuildReleaseTrust(root, {})).toThrow("Supply");
    mkdirSync(join(root, ".development"));
    writeFileSync(
      join(root, ".development/hosted-release-trust.json"),
      JSON.stringify(keys),
    );
    expect(JSON.parse(resolveBuildReleaseTrust(root, {}))).toEqual(keys);
    const explicit = {
      customer: { key: Buffer.alloc(32, 2).toString("base64") },
    };
    expect(
      JSON.parse(
        resolveBuildReleaseTrust(root, {
          SYNTILA_RELEASE_TRUST_KEYS_JSON: JSON.stringify(explicit),
        }),
      ),
    ).toEqual(explicit);
    expect(() =>
      resolveBuildReleaseTrust(root, {
        SYNTILA_RELEASE_TRUST_KEYS_JSON: "{}",
      }),
    ).toThrow("at least one");
    expect(() =>
      resolveBuildReleaseTrust(root, {
        SYNTILA_RELEASE_TRUST_KEYS_JSON: '{"p":{"k":"invalid"}}',
      }),
    ).toThrow("Ed25519");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
