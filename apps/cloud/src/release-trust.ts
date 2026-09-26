export function canonicalReleaseJson(value: unknown): string {
  if (Array.isArray(value)) {
    return `[${value.map(canonicalReleaseJson).join(",")}]`;
  }
  if (value && typeof value === "object") {
    const record = value as Record<string, unknown>;
    return `{${Object.keys(record)
      .sort()
      .map(
        (key) => `${JSON.stringify(key)}:${canonicalReleaseJson(record[key])}`,
      )
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

export async function verifyEd25519ReleaseSignature(args: {
  trustKeysJson?: string;
  publisher: string;
  signingKeyId: string;
  signature: string;
  message: string;
}): Promise<boolean> {
  if (!args.trustKeysJson) return false;
  try {
    const trust = JSON.parse(args.trustKeysJson) as Record<
      string,
      Record<string, string>
    >;
    const encoded = trust[args.publisher]?.[args.signingKeyId];
    if (!encoded) return false;
    const publicKey = Uint8Array.from(atob(encoded), (char) =>
      char.charCodeAt(0),
    );
    const signature = Uint8Array.from(atob(args.signature), (char) =>
      char.charCodeAt(0),
    );
    if (publicKey.length !== 32 || signature.length !== 64) return false;
    const key = await crypto.subtle.importKey(
      "raw",
      publicKey,
      { name: "Ed25519" },
      false,
      ["verify"],
    );
    return crypto.subtle.verify(
      { name: "Ed25519" },
      key,
      signature,
      new TextEncoder().encode(args.message),
    );
  } catch {
    return false;
  }
}
