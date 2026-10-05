import {
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
  randomUUID,
  sign,
  verify,
} from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseEnv } from "node:util";

const names = [
  "CONCLAVE_RELEASE_PRIVATE_KEY",
  "CONCLAVE_RELEASE_PUBLISHER",
  "CONCLAVE_RELEASE_SIGNING_KEY_ID",
  "CONCLAVE_RELEASE_TRUST_KEYS_JSON",
];

// Only the local Wrangler secret file holds private material. Desktop builds
// receive the public roots; customer builds never load these files implicitly.
export function setupDevelopmentProfileSigning(root, { hosted = false } = {}) {
  const directory = join(root, ".development");
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const file = hosted
    ? join(directory, "hosted-profile-signing.vars")
    : join(root, "apps/cloud/.dev.vars");
  const previous = existsSync(file) ? readFileSync(file, "utf8") : "";
  const values = parseEnv(previous);
  const configured = names.filter((name) => values[name]?.trim());
  if (configured.length !== 0 && configured.length !== names.length) {
    throw new Error(
      "Partial local Profile signer configuration. Complete all four signing settings in apps/cloud/.dev.vars; existing values were preserved.",
    );
  }
  let generated = false;
  if (configured.length === 0) {
    const keys = generateKeyPairSync("ed25519");
    const publisher = "conclave-development";
    const keyId = `local-profile-${randomUUID()}`;
    const privateBytes = keys.privateKey.export({
      format: "der",
      type: "pkcs8",
    });
    const publicBytes = keys.publicKey.export({ format: "der", type: "spki" });
    Object.assign(values, {
      CONCLAVE_RELEASE_PRIVATE_KEY: privateBytes
        .subarray(-32)
        .toString("base64"),
      CONCLAVE_RELEASE_PUBLISHER: publisher,
      CONCLAVE_RELEASE_SIGNING_KEY_ID: keyId,
      CONCLAVE_RELEASE_TRUST_KEYS_JSON: JSON.stringify({
        [publisher]: { [keyId]: publicBytes.subarray(-32).toString("base64") },
      }),
    });
    const appended = names
      .map((name) => `${name}='${values[name]}'`)
      .join("\n");
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(
      file,
      `${previous}${previous.endsWith("\n") || !previous ? "" : "\n"}\n# Local development Profile signing; never deploy these keys.\n${appended}\n`,
      { mode: 0o600 },
    );
    generated = true;
  }
  chmodSync(file, 0o600);
  let roots;
  try {
    roots = JSON.parse(values.CONCLAVE_RELEASE_TRUST_KEYS_JSON);
    let bytes = Buffer.from(values.CONCLAVE_RELEASE_PRIVATE_KEY, "base64");
    const privateKey = values.CONCLAVE_RELEASE_PRIVATE_KEY.includes(
      "-----BEGIN",
    )
      ? createPrivateKey(values.CONCLAVE_RELEASE_PRIVATE_KEY)
      : createPrivateKey({
          key:
            bytes.length === 32
              ? Buffer.concat([
                  Buffer.from("302e020100300506032b657004220420", "hex"),
                  bytes,
                ])
              : bytes,
          format: "der",
          type: "pkcs8",
        });
    const raw = Buffer.from(
      roots[values.CONCLAVE_RELEASE_PUBLISHER][
        values.CONCLAVE_RELEASE_SIGNING_KEY_ID
      ],
      "base64",
    );
    if (raw.length !== 32) throw new Error();
    const publicKey = createPublicKey({
      key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), raw]),
      format: "der",
      type: "spki",
    });
    const challenge = Buffer.from(
      "conclave-development-profile-signing-preflight-v1",
    );
    if (!verify(null, challenge, publicKey, sign(null, challenge, privateKey)))
      throw new Error();
  } catch {
    throw new Error(
      "Local Profile signer does not match its public trust roots. Existing keys were preserved.",
    );
  }
  writeFileSync(
    join(
      directory,
      hosted ? "hosted-profile-trust.json" : "profile-trust.json",
    ),
    `${JSON.stringify(roots)}\n`,
  );
  if (hosted) {
    // Wrangler secret bulk accepts this file without putting private bytes in
    // command arguments, terminal output, desktop artifacts, or version control.
    writeFileSync(
      join(directory, "hosted-profile-signing.json"),
      JSON.stringify(
        Object.fromEntries(names.map((name) => [name, values[name]])),
      ),
      { mode: 0o600 },
    );
    chmodSync(join(directory, "hosted-profile-signing.json"), 0o600);
  }
  return { generated, roots };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  try {
    const root = fileURLToPath(new URL("../", import.meta.url));
    const hosted = process.argv.includes("--hosted");
    const result = setupDevelopmentProfileSigning(root, { hosted });
    console.log(
      process.argv.includes("--public-trust")
        ? JSON.stringify(result.roots)
        : `${hosted ? "Hosted development" : "Local"} Profile signer ${result.generated ? "created" : "verified"}. Public roots: .development/${hosted ? "hosted-profile-trust" : "profile-trust"}.json. Private material remains in ignored files.`,
    );
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
