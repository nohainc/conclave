import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

export function resolveBuildReleaseTrust(root, env = process.env) {
  let value = env.CONCLAVE_RELEASE_TRUST_KEYS_JSON;
  if (!value) {
    const hosted = join(root, ".development/hosted-release-trust.json");
    if (!existsSync(hosted)) {
      throw new Error(
        "Supply CONCLAVE_RELEASE_TRUST_KEYS_JSON or configure hosted application-release trust before building.",
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
      "Application release trust must contain at least one public signing key.",
    );
  }
  for (const publisher of Object.values(keys)) {
    if (
      !publisher ||
      typeof publisher !== "object" ||
      Array.isArray(publisher) ||
      Object.keys(publisher).length === 0
    ) {
      throw new Error("Invalid public application-release trust configuration.");
    }
    for (const key of Object.values(publisher)) {
      if (typeof key !== "string" || Buffer.from(key, "base64").length !== 32) {
        throw new Error("Application-release trust requires raw Ed25519 public keys.");
      }
    }
  }
  return JSON.stringify(keys);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.stdout.write(
    resolveBuildReleaseTrust(fileURLToPath(new URL("../", import.meta.url))),
  );
}
