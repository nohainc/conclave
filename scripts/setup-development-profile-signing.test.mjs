import {
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseEnv } from "node:util";
import { afterEach, describe, expect, it } from "vitest";
import { setupDevelopmentProfileSigning } from "./setup-development-profile-signing.mjs";

const directories = [];
function temporaryRoot() {
  const root = mkdtempSync(join(tmpdir(), "conclave-profile-signing-"));
  directories.push(root);
  return root;
}
afterEach(() => {
  for (const root of directories.splice(0)) rmSync(root, { recursive: true });
});

describe("development Profile signing setup", () => {
  it("creates private local material separately from desktop public trust", () => {
    const root = temporaryRoot();
    const result = setupDevelopmentProfileSigning(root);
    expect(result.generated).toBe(true);
    const file = join(root, "apps/cloud/.dev.vars");
    const secrets = parseEnv(readFileSync(file, "utf8"));
    expect(statSync(file).mode & 0o777).toBe(0o600);
    const publicText = readFileSync(
      join(root, ".development/profile-trust.json"),
      "utf8",
    );
    expect(JSON.parse(publicText)).toEqual(result.roots);
    expect(publicText).not.toContain(secrets.CONCLAVE_RELEASE_PRIVATE_KEY);
    expect(Object.keys(result.roots)).toEqual(["conclave-development"]);
  });
  it("reuses keys and preserves unrelated local configuration", () => {
    const root = temporaryRoot();
    const first = setupDevelopmentProfileSigning(root);
    const file = join(root, "apps/cloud/.dev.vars");
    const original =
      readFileSync(file, "utf8") + "BETTER_AUTH_SECRET=fixture-only\n";
    writeFileSync(file, original);
    const second = setupDevelopmentProfileSigning(root);
    expect(second.generated).toBe(false);
    expect(second.roots).toEqual(first.roots);
    expect(readFileSync(file, "utf8")).toBe(original);
  });
  it("does not replace partial signer configuration", () => {
    const root = temporaryRoot();
    setupDevelopmentProfileSigning(root);
    const file = join(root, "apps/cloud/.dev.vars");
    const partial = "CONCLAVE_RELEASE_PUBLISHER=existing\n";
    writeFileSync(file, partial);
    expect(() => setupDevelopmentProfileSigning(root)).toThrow(
      "Partial local Profile signer configuration",
    );
    expect(readFileSync(file, "utf8")).toBe(partial);
  });
  it("rejects mismatched keys without changing or disclosing them", () => {
    const root = temporaryRoot();
    setupDevelopmentProfileSigning(root);
    const other = temporaryRoot();
    setupDevelopmentProfileSigning(other);
    const alternate = parseEnv(
      readFileSync(join(other, "apps/cloud/.dev.vars"), "utf8"),
    );
    const file = join(root, "apps/cloud/.dev.vars");
    const mismatched = readFileSync(file, "utf8").replace(
      /^CONCLAVE_RELEASE_PRIVATE_KEY=.*$/m,
      `CONCLAVE_RELEASE_PRIVATE_KEY='${alternate.CONCLAVE_RELEASE_PRIVATE_KEY}'`,
    );
    writeFileSync(file, mismatched);
    expect(() => setupDevelopmentProfileSigning(root)).toThrow(
      "Local Profile signer does not match",
    );
    expect(readFileSync(file, "utf8")).toBe(mismatched);
  });
  it("keeps hosted development keys independent from localhost keys", () => {
    const root = temporaryRoot();
    const local = setupDevelopmentProfileSigning(root);
    const hosted = setupDevelopmentProfileSigning(root, { hosted: true });
    expect(hosted.roots).not.toEqual(local.roots);
    const file = join(root, ".development/hosted-profile-signing.json");
    expect(statSync(file).mode & 0o777).toBe(0o600);
    expect(
      JSON.parse(readFileSync(file, "utf8")).CONCLAVE_RELEASE_TRUST_KEYS_JSON,
    ).toBe(JSON.stringify(hosted.roots));
    expect(
      setupDevelopmentProfileSigning(root, { hosted: true }).roots,
    ).toEqual(hosted.roots);
  });
});
