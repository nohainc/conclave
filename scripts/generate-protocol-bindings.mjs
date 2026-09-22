import { readFile, writeFile } from "node:fs/promises";

const schemaPath = "packages/protocol/schema/conclave-message.schema.json";
const schema = JSON.parse(await readFile(schemaPath, "utf8"));
const protocolName = schema.properties.protocol.const;
const protocolVersion = schema["x-protocol-version"];
const messageTypes = schema["x-message-types"];
const messagePayloads = schema["x-message-payloads"];
const requiredFields = schema.required;

if (
  typeof protocolName !== "string" ||
  typeof protocolVersion !== "string" ||
  !Array.isArray(requiredFields) ||
  requiredFields.some((field) => typeof field !== "string") ||
  !Array.isArray(messageTypes) ||
  messageTypes.length === 0 ||
  messageTypes.some((messageType) => typeof messageType !== "string") ||
  typeof messagePayloads !== "object" ||
  messagePayloads === null ||
  messageTypes.some(
    (messageType) => typeof messagePayloads[messageType] !== "string",
  )
) {
  throw new Error("canonical protocol schema is missing generator metadata");
}

const tsFields = requiredFields
  .map((field) => `  ${JSON.stringify(field)},`)
  .join("\n");
const tsMessageTypes = messageTypes
  .map((messageType) => `  ${JSON.stringify(messageType)},`)
  .join("\n");
const tsPayloads = messageTypes
  .map(
    (messageType) =>
      `  ${messageType}: ${JSON.stringify(messagePayloads[messageType])},`,
  )
  .join("\n");
const ts = `// GENERATED FILE. Do not edit by hand.\n\nexport const PROTOCOL_NAME = ${JSON.stringify(protocolName)} as const;\nexport const PROTOCOL_VERSION = ${JSON.stringify(protocolVersion)} as const;\nexport const REQUIRED_ENVELOPE_FIELDS = [\n${tsFields}\n] as const;\nexport const PROTOCOL_MESSAGE_TYPES = [\n${tsMessageTypes}\n] as const;\nexport const PROTOCOL_MESSAGE_PAYLOAD_SCHEMAS = {\n${tsPayloads}\n} as const;\n`;
const dartFields = requiredFields.map((field) => `  '${field}',`).join("\n");
const dartMessageTypes = messageTypes
  .map((messageType) => `  '${messageType}',`)
  .join("\n");
const dartPayloads = messageTypes
  .map(
    (messageType) =>
      `  '${messageType}': '${messagePayloads[messageType].replaceAll("$", "\\$")}',`,
  )
  .join("\n");
const dart = `// GENERATED FILE. Do not edit by hand.\n\nconst protocolName = '${protocolName}';\nconst protocolVersion = '${protocolVersion}';\nconst requiredEnvelopeFields = <String>[\n${dartFields}\n];\nconst protocolMessageTypes = <String>{\n${dartMessageTypes}\n};\nconst protocolMessagePayloadSchemas = <String, String>{\n${dartPayloads}\n};\n`;

await writeFile("packages/protocol/src/generated.ts", ts);
await writeFile("packages/dart/protocol/lib/generated_protocol.dart", dart);
