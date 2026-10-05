import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

export function resolveBuildProfileTrust(root, env = process.env) {
  let value = env.CONCLAVE_RELEASE_TRUST_KEYS_JSON;
  if (!value) {
    if (env.CONCLAVE_MACOS_SIGN_IDENTITY) {
      throw new Error(
        "Signed builds require explicit CONCLAVE_RELEASE_TRUST_KEYS_JSON; development trust is never selected automatically.",
      );
    }
    const hosted = join(root, ".development/hosted-profile-trust.json");
    if (!existsSync(hosted)) {
      throw new Error(
        "Supply CONCLAVE_RELEASE_TRUST_KEYS_JSON or configure hosted development Profile signing before building.",
      );
    }
    value = readFileSync(hosted, "utf8");
  }
  const keys = JSON.parse(value);
  if (
    !keys ||
    typeof keys !== "object" ||
    Array.isArray(keys) ||
    Object.keys(keys).length === 0
  ) {
    throw new Error(
      "Profile release trust must contain at least one public signing key.",
    );
  }
  for (const publisher of Object.values(keys)) {
    if (
      !publisher ||
      typeof publisher !== "object" ||
      Array.isArray(publisher) ||
      Object.keys(publisher).length === 0
    )
      throw new Error("Invalid public Profile trust configuration.");
    for (const key of Object.values(publisher)) {
      if (typeof key !== "string" || Buffer.from(key, "base64").length !== 32)
        throw new Error("Profile trust requires raw Ed25519 public keys.");
    }
  }
  return JSON.stringify(keys);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.stdout.write(
    resolveBuildProfileTrust(fileURLToPath(new URL("../", import.meta.url))),
  );
}
