import { readFile, writeFile } from "node:fs/promises";

const schemaPath = "packages/protocol/schema/conclave-message.schema.json";
const schema = JSON.parse(await readFile(schemaPath, "utf8"));
const protocolName = schema.properties.protocol.const;
const protocolVersion = schema["x-protocol-version"];
const requiredFields = schema.required;

if (
  typeof protocolName !== "string" ||
  typeof protocolVersion !== "string" ||
  !Array.isArray(requiredFields) ||
  requiredFields.some((field) => typeof field !== "string")
) {
  throw new Error("canonical protocol schema is missing generator metadata");
}

const tsFields = requiredFields
  .map((field) => `  ${JSON.stringify(field)},`)
  .join("\n");
const ts = `// GENERATED FILE. Do not edit by hand.\n\nexport const PROTOCOL_NAME = ${JSON.stringify(protocolName)} as const;\nexport const PROTOCOL_VERSION = ${JSON.stringify(protocolVersion)} as const;\nexport const REQUIRED_ENVELOPE_FIELDS = [\n${tsFields}\n] as const;\n`;
const dartFields = requiredFields.map((field) => `  '${field}',`).join("\n");
const dart = `// GENERATED FILE. Do not edit by hand.\n\nconst protocolName = '${protocolName}';\nconst protocolVersion = '${protocolVersion}';\nconst requiredEnvelopeFields = <String>[\n${dartFields}\n];\n`;

await writeFile("packages/protocol/src/generated.ts", ts);
await writeFile("packages/dart/protocol/lib/generated_protocol.dart", dart);
