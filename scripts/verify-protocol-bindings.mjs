import { readFile } from "node:fs/promises";

const read = (path) => readFile(path, "utf8");

const schema = JSON.parse(
  await readFile(
    "packages/protocol/schema/conclave-message.schema.json",
    "utf8",
  ),
);
if (schema.properties.protocol.const !== "conclave.protocol") {
  throw new Error("canonical protocol schema has an unexpected protocol name");
}
const requiredFields = [
  "protocol",
  "version",
  "messageId",
  "goalId",
  "runId",
  "workerId",
  "createdAt",
  "messageType",
  "payload",
];
for (const field of requiredFields) {
  if (!schema.required.includes(field)) {
    throw new Error(`canonical protocol schema is missing ${field}`);
  }
}
if (!schema.properties.version.pattern.includes("[0-9]+")) {
  throw new Error("canonical protocol schema does not constrain versions");
}

const [dart, typescript, fixtureText] = await Promise.all([
  read("packages/dart/protocol/lib/conclave_protocol.dart"),
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
  if (!typescript.includes(`export const ${field}`)) {
    throw new Error(`TypeScript binding is missing ${field}`);
  }
}
if (!typescript.includes(`PROTOCOL_VERSION = "${fixture.version}"`)) {
  throw new Error("TypeScript protocol version does not match the fixture");
}
if (!dart.includes(`const protocolVersion = '${fixture.version}'`)) {
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
globalThis.console.log(
  "Protocol schema, fixture, TypeScript, and Dart bindings are aligned.",
);
