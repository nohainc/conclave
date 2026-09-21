import { readFile } from "node:fs/promises";

const schema = JSON.parse(
  await readFile(
    "packages/protocol/schema/conclave-message.schema.json",
    "utf8",
  ),
);
if (schema.properties.protocol.const !== "conclave.protocol") {
  throw new Error("canonical protocol schema has an unexpected protocol name");
}
if (!schema.required.includes("goalId") || !schema.required.includes("runId")) {
  throw new Error("canonical protocol schema is missing correlation fields");
}
const dart = await readFile(
  "packages/dart/protocol/lib/conclave_protocol.dart",
  "utf8",
);
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
console.log("Protocol schema and Dart bindings are present and aligned.");
