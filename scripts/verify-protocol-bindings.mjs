import { readFile } from "node:fs/promises";

const read = (path) => readFile(path, "utf8");

const schema = JSON.parse(
  await readFile(
    "packages/protocol/schema/conclave-message.schema.json",
    "utf8",
  ),
);
if (schema["x-protocol-version"] !== "0.1") {
  throw new Error("canonical protocol schema has an unexpected version");
}
if (schema.properties.protocol.const !== "conclave.protocol") {
  throw new Error("canonical protocol schema has an unexpected protocol name");
}
const requiredFields = schema.required;
const messageTypes = schema["x-message-types"];
const messagePayloads = schema["x-message-payloads"];
if (
  !Array.isArray(requiredFields) ||
  requiredFields.some((field) => typeof field !== "string")
) {
  throw new Error("canonical protocol schema has invalid required fields");
}
if (
  !Array.isArray(messageTypes) ||
  messageTypes.length === 0 ||
  messageTypes.some((messageType) => typeof messageType !== "string")
) {
  throw new Error("canonical protocol schema has invalid message types");
}
if (
  typeof messagePayloads !== "object" ||
  messagePayloads === null ||
  messageTypes.some(
    (messageType) =>
      typeof messagePayloads[messageType] !== "string" ||
      !messagePayloads[messageType].startsWith("#/$defs/") ||
      !Object.hasOwn(
        schema.$defs ?? {},
        messagePayloads[messageType].slice("#/$defs/".length),
      ),
  )
) {
  throw new Error(
    "canonical protocol schema must map every message to a payload definition",
  );
}
for (const field of requiredFields) {
  if (!schema.required.includes(field)) {
    throw new Error(`canonical protocol schema is missing ${field}`);
  }
}
if (!schema.properties.version.pattern.includes("[0-9]+")) {
  throw new Error("canonical protocol schema does not constrain versions");
}

const [
  dart,
  generatedDart,
  generated,
  agentGenerated,
  typescript,
  fixtureText,
] = await Promise.all([
  read("packages/dart/protocol/lib/conclave_protocol.dart"),
  read("packages/dart/protocol/lib/generated_protocol.dart"),
  read("packages/protocol/src/generated.ts"),
  read("packages/agent-protocol/src/generated.ts"),
  read("packages/protocol/src/index.ts"),
  read("packages/protocol/fixtures/task-request.json"),
]);
const fixture = JSON.parse(fixtureText);
for (const field of requiredFields) {
  if (!(field in fixture)) {
    throw new Error(`canonical fixture is missing ${field}`);
  }
}
if (fixture.protocol !== schema.properties.protocol.const) {
  throw new Error("canonical fixture protocol does not match the schema");
}
if (
  fixture.messageType !== "TaskRequest" ||
  typeof fixture.payload !== "object"
) {
  throw new Error("canonical TaskRequest fixture is malformed");
}
for (const field of ["PROTOCOL_NAME", "PROTOCOL_VERSION"]) {
  if (!generated.includes(`export const ${field}`)) {
    throw new Error(`generated TypeScript binding is missing ${field}`);
  }
}
if (!generated.includes(`PROTOCOL_VERSION = "${fixture.version}"`)) {
  throw new Error("TypeScript protocol version does not match the fixture");
}
if (!typescript.includes('from "./generated.js"')) {
  throw new Error(
    "TypeScript protocol binding does not import generated constants",
  );
}
const agentProtocol = schema["x-agent-protocol"];
if (
  !agentGenerated.includes(
    `AGENT_PROTOCOL_NAME = ${JSON.stringify(agentProtocol.name)}`,
  ) ||
  !agentGenerated.includes(
    `AGENT_PROTOCOL_VERSION = ${JSON.stringify(agentProtocol.version)}`,
  )
) {
  throw new Error("generated Agent protocol binding is out of date");
}
for (const messageType of agentProtocol.messageTypes) {
  if (!agentGenerated.includes(JSON.stringify(messageType))) {
    throw new Error(
      `generated Agent protocol binding is missing ${messageType}`,
    );
  }
}
if (!generatedDart.includes(`const protocolVersion = '${fixture.version}'`)) {
  throw new Error("Dart protocol version does not match the fixture");
}
for (const field of [
  "messageId",
  "goalId",
  "runId",
  "workerId",
  "messageType",
]) {
  if (!dart.includes(`'${field}'`)) {
    throw new Error(`Dart binding is missing ${field}`);
  }
}
for (const messageType of messageTypes) {
  if (!generated.includes(JSON.stringify(messageType))) {
    throw new Error(`generated TypeScript binding is missing ${messageType}`);
  }
  if (!generatedDart.includes(`'${messageType}'`)) {
    throw new Error(`generated Dart binding is missing ${messageType}`);
  }
  if (!generated.includes(`PROTOCOL_MESSAGE_PAYLOAD_SCHEMAS`)) {
    throw new Error("generated TypeScript binding is missing payload schemas");
  }
  if (!generatedDart.includes(`protocolMessagePayloadSchemas`)) {
    throw new Error("generated Dart binding is missing payload schemas");
  }
}
globalThis.console.log(
  "Protocol schema, fixture, TypeScript, and Dart bindings are aligned.",
);
