import { readFile } from "node:fs/promises";

const read = (path) => readFile(path, "utf8");
const schema = JSON.parse(
  await read("packages/protocol/schema/conclave-message.schema.json"),
);
const [
  protocolTs,
  hostTs,
  dart,
  protocolIndex,
  hostIndex,
  dartIndex,
  workerPackage,
  workspaceDart,
] = await Promise.all([
  read("packages/protocol/src/generated.ts"),
  read("packages/host-protocol/src/generated.ts"),
  read("packages/dart/protocol/lib/generated_protocol.dart"),
  read("packages/protocol/src/index.ts"),
  read("packages/host-protocol/src/index.ts"),
  read("packages/dart/protocol/lib/conclave_protocol.dart"),
  read("packages/conclave_worker_protocol/lib/src/protocol_version.dart"),
  read("packages/dart/protocol/lib/workspace_runtime_protocol.dart"),
]);

const retiredSchemaKeys = [
  "x-agent-protocol",
  "x-local-protocols",
  "x-worker-protocol",
];
for (const key of retiredSchemaKeys) {
  if (Object.hasOwn(schema, key)) {
    throw new Error(
      `canonical schema still defines retired protocol metadata: ${key}`,
    );
  }
}
for (const message of [
  "worker.install",
  "worker.remove",
  "worker.status",
  "credential.status",
]) {
  if (schema["x-host-protocol"].messageTypes.includes(message)) {
    throw new Error(
      `canonical schema still defines retired message ${message}`,
    );
  }
}
if (
  schema.$defs.assignmentSnapshot.required.includes("resolvedWorkerVersion")
) {
  throw new Error("assignment snapshot still requires a legacy Worker version");
}

const generatedFiles = [protocolTs, hostTs, dart];
const forbiddenGeneratedTokens = [
  "AGENT_PROTOCOL_",
  "agentProtocolName",
  "AGENT_APP_IPC_",
  "WORKER_PLUGIN_",
  "worker" + "PluginProtocolName",
  "workerProtocolName",
  "worker.install",
  "worker.remove",
  "credential.status",
  "resolvedWorkerVersion",
];
for (const token of forbiddenGeneratedTokens) {
  if (generatedFiles.some((contents) => contents.includes(token))) {
    throw new Error(
      `generated bindings still contain retired protocol field: ${token}`,
    );
  }
}
for (const code of schema["x-execution-error-codes"]) {
  if (
    !protocolTs.includes(JSON.stringify(code)) ||
    !dart.includes(`'${code}'`)
  ) {
    throw new Error(`generated execution error bindings are missing ${code}`);
  }
}
for (const type of schema["x-message-types"]) {
  if (
    !protocolTs.includes(JSON.stringify(type)) ||
    !dart.includes(`'${type}'`)
  ) {
    throw new Error(`generated product protocol bindings are missing ${type}`);
  }
}
for (const type of schema["x-host-protocol"].messageTypes) {
  if (
    !protocolTs.includes(JSON.stringify(type)) ||
    !hostTs.includes(JSON.stringify(type))
  ) {
    throw new Error(
      `generated Workspace protocol bindings are missing ${type}`,
    );
  }
}
for (const type of schema["x-realtime-events"].durableTypes.concat(
  schema["x-realtime-events"].ephemeralTypes,
)) {
  if (
    !protocolTs.includes(JSON.stringify(type)) ||
    !hostTs.includes(JSON.stringify(type))
  ) {
    throw new Error(`generated realtime event bindings are missing ${type}`);
  }
}
if (
  protocolIndex.includes("generated-local-protocols") ||
  protocolIndex.includes("AGENT_PROTOCOL_") ||
  hostIndex.includes("AGENT_PROTOCOL_") ||
  dartIndex.includes("generated_local_protocols") ||
  [
    "worker.install",
    "worker.remove",
    "worker.status",
    "credential.status",
  ].some((message) => workspaceDart.includes(`'${message}'`)) ||
  !workerPackage.includes("localWorkerProtocolVersion = '4.0'")
) {
  throw new Error(
    "protocol exports do not use the current schema and Worker Protocol package",
  );
}

console.log("Current protocol schema and generated bindings are aligned.");
