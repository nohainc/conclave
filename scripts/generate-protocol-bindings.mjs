import { readFile, writeFile } from "node:fs/promises";

const schemaPath = "packages/protocol/schema/conclave-message.schema.json";
const schema = JSON.parse(await readFile(schemaPath, "utf8"));
const protocolName = schema.properties.protocol.const;
const protocolVersion = schema["x-protocol-version"];
const messageTypes = schema["x-message-types"];
const messagePayloads = schema["x-message-payloads"];
const requiredFields = schema.required;
const hostProtocol = schema["x-host-protocol"];
const workerProtocol = schema["x-worker-protocol"];
const agentProtocol = schema["x-agent-protocol"];
const localProtocols = schema["x-local-protocols"];

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
  ) ||
  typeof hostProtocol !== "object" ||
  hostProtocol === null ||
  typeof hostProtocol.name !== "string" ||
  typeof hostProtocol.version !== "string" ||
  typeof hostProtocol.maxMessageSizeBytes !== "number" ||
  !Array.isArray(hostProtocol.messageTypes) ||
  !Array.isArray(hostProtocol.baseEnvelopeFields) ||
  !Array.isArray(hostProtocol.assignmentEnvelopeFields) ||
  typeof workerProtocol !== "object" ||
  workerProtocol === null ||
  typeof workerProtocol.name !== "string" ||
  typeof workerProtocol.version !== "string" ||
  typeof workerProtocol.jsonRpcVersion !== "string" ||
  !Array.isArray(workerProtocol.methods) ||
  !Array.isArray(workerProtocol.notifications)
) {
  throw new Error("canonical protocol schema is missing generator metadata");
}

const hostMessageTypes = hostProtocol.messageTypes
  .map((messageType) => `  ${JSON.stringify(messageType)},`)
  .join("\n");
const hostBaseFields = hostProtocol.baseEnvelopeFields
  .map((field) => `  ${JSON.stringify(field)},`)
  .join("\n");
const hostAssignmentFields = hostProtocol.assignmentEnvelopeFields
  .map((field) => `  ${JSON.stringify(field)},`)
  .join("\n");

const workerMethods = workerProtocol.methods
  .map((method) => `  ${JSON.stringify(method)},`)
  .join("\n");
const workerNotifications = workerProtocol.notifications
  .map((method) => `  ${JSON.stringify(method)},`)
  .join("\n");

const agentMessageTypes = (agentProtocol?.messageTypes ?? [])
  .map((messageType) => `  ${JSON.stringify(messageType)},`)
  .join("\n");
const agentBaseFields = (agentProtocol?.baseEnvelopeFields ?? [])
  .map((field) => `  ${JSON.stringify(field)},`)
  .join("\n");
const agentAssignmentFields = (agentProtocol?.assignmentEnvelopeFields ?? [])
  .map((field) => `  ${JSON.stringify(field)},`)
  .join("\n");
const ipcCommandTypes = (localProtocols?.agentAppIpc?.commandTypes ?? [])
  .map((type) => `  ${JSON.stringify(type)},`)
  .join("\n");
const pluginMethods = (localProtocols?.workerPlugin?.methods ?? [])
  .map((method) => `  ${JSON.stringify(method)},`)
  .join("\n");
const pluginNotifications = (localProtocols?.workerPlugin?.notifications ?? [])
  .map((method) => `  ${JSON.stringify(method)},`)
  .join("\n");

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
const ts = `// GENERATED FILE. Do not edit by hand.

export const PROTOCOL_NAME = ${JSON.stringify(protocolName)} as const;
export const PROTOCOL_VERSION = ${JSON.stringify(protocolVersion)} as const;
export const REQUIRED_ENVELOPE_FIELDS = [
${tsFields}
] as const;
export const PROTOCOL_MESSAGE_TYPES = [
${tsMessageTypes}
] as const;
export const PROTOCOL_MESSAGE_PAYLOAD_SCHEMAS = {
${tsPayloads}
} as const;

export const HOST_PROTOCOL_NAME = ${JSON.stringify(hostProtocol.name)} as const;
export const HOST_PROTOCOL_VERSION = ${JSON.stringify(hostProtocol.version)} as const;
export const HOST_PROTOCOL_MAX_MESSAGE_SIZE_BYTES = ${hostProtocol.maxMessageSizeBytes} as const;
export const HOST_PROTOCOL_MESSAGE_TYPES = [
${hostMessageTypes}
] as const;
export const HOST_PROTOCOL_BASE_ENVELOPE_FIELDS = [
${hostBaseFields}
] as const;
export const HOST_PROTOCOL_ASSIGNMENT_ENVELOPE_FIELDS = [
${hostAssignmentFields}
] as const;

export const AGENT_PROTOCOL_NAME = ${JSON.stringify(agentProtocol?.name ?? "conclave.agent-protocol")} as const;
export const AGENT_PROTOCOL_VERSION = ${JSON.stringify(agentProtocol?.version ?? "2.0")} as const;
export const AGENT_PROTOCOL_MAX_MESSAGE_SIZE_BYTES = ${agentProtocol?.maxMessageSizeBytes ?? 4194304} as const;
export const AGENT_PROTOCOL_MESSAGE_TYPES = [
${agentMessageTypes}
] as const;
export const AGENT_PROTOCOL_BASE_ENVELOPE_FIELDS = [
${agentBaseFields}
] as const;
export const AGENT_PROTOCOL_ASSIGNMENT_ENVELOPE_FIELDS = [
${agentAssignmentFields}
] as const;
`;
const hostTs = `// GENERATED FILE. Do not edit by hand.

export const HOST_PROTOCOL_NAME = ${JSON.stringify(hostProtocol.name)} as const;
export const HOST_PROTOCOL_VERSION = ${JSON.stringify(hostProtocol.version)} as const;
export const HOST_PROTOCOL_MAX_MESSAGE_SIZE_BYTES = ${hostProtocol.maxMessageSizeBytes} as const;
export const HOST_PROTOCOL_MESSAGE_TYPES = [
${hostMessageTypes}
] as const;
export const HOST_PROTOCOL_BASE_ENVELOPE_FIELDS = [
${hostBaseFields}
] as const;
export const HOST_PROTOCOL_ASSIGNMENT_ENVELOPE_FIELDS = [
${hostAssignmentFields}
] as const;

export const WORKER_PROTOCOL_NAME = ${JSON.stringify(workerProtocol.name)} as const;
export const WORKER_PROTOCOL_VERSION = ${JSON.stringify(workerProtocol.version)} as const;
export const WORKER_PROTOCOL_JSON_RPC_VERSION = ${JSON.stringify(workerProtocol.jsonRpcVersion)} as const;
export const WORKER_PROTOCOL_METHODS = [
${workerMethods}
] as const;
export const WORKER_PROTOCOL_NOTIFICATIONS = [
${workerNotifications}
] as const;

export const AGENT_PROTOCOL_NAME = ${JSON.stringify(agentProtocol?.name ?? "conclave.agent-protocol")} as const;
export const AGENT_PROTOCOL_VERSION = ${JSON.stringify(agentProtocol?.version ?? "2.0")} as const;
export const AGENT_PROTOCOL_MAX_MESSAGE_SIZE_BYTES = ${agentProtocol?.maxMessageSizeBytes ?? 4194304} as const;
export const AGENT_PROTOCOL_MESSAGE_TYPES = [
${agentMessageTypes}
] as const;
export const AGENT_PROTOCOL_BASE_ENVELOPE_FIELDS = [
${agentBaseFields}
] as const;
export const AGENT_PROTOCOL_ASSIGNMENT_ENVELOPE_FIELDS = [
${agentAssignmentFields}
] as const;
`;
const localTs = `// GENERATED FILE. Do not edit by hand.

export const WORKER_PROTOCOL_NAME = ${JSON.stringify(workerProtocol.name)} as const;
export const WORKER_PROTOCOL_VERSION = ${JSON.stringify(workerProtocol.version)} as const;
export const WORKER_PROTOCOL_JSON_RPC_VERSION = ${JSON.stringify(workerProtocol.jsonRpcVersion)} as const;
export const WORKER_PROTOCOL_METHODS = [
${workerMethods}
] as const;
export const WORKER_PROTOCOL_NOTIFICATIONS = [
${workerNotifications}
] as const;

export const AGENT_APP_IPC_PROTOCOL_NAME = ${JSON.stringify(localProtocols?.agentAppIpc?.name ?? "conclave.agent-app-ipc")} as const;
export const AGENT_APP_IPC_PROTOCOL_VERSION = ${JSON.stringify(localProtocols?.agentAppIpc?.version ?? "1.0")} as const;
export const AGENT_APP_IPC_MAX_FRAME_BYTES = ${localProtocols?.agentAppIpc?.maxFrameBytes ?? 1048576} as const;
export const AGENT_APP_IPC_COMMAND_TYPES = [
${ipcCommandTypes}
] as const;
export const WORKER_PLUGIN_PROTOCOL_NAME = ${JSON.stringify(localProtocols?.workerPlugin?.name ?? "conclave.worker-plugin")} as const;
export const WORKER_PLUGIN_PROTOCOL_VERSION = ${JSON.stringify(localProtocols?.workerPlugin?.version ?? "2.0")} as const;
export const WORKER_PLUGIN_JSON_RPC_VERSION = ${JSON.stringify(localProtocols?.workerPlugin?.jsonRpcVersion ?? "2.0")} as const;
export const WORKER_PLUGIN_METHODS = [
${pluginMethods}
] as const;
export const WORKER_PLUGIN_NOTIFICATIONS = [
${pluginNotifications}
] as const;
`;
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

const dartHostMessageTypes = hostProtocol.messageTypes
  .map((messageType) => `  '${messageType}',`)
  .join("\n");
const dartHostBaseFields = hostProtocol.baseEnvelopeFields
  .map((field) => `  '${field}',`)
  .join("\n");
const dartHostAssignmentFields = hostProtocol.assignmentEnvelopeFields
  .map((field) => `  '${field}',`)
  .join("\n");

const dartWorkerMethods = workerProtocol.methods
  .map((method) => `  '${method}',`)
  .join("\n");
const dartWorkerNotifications = workerProtocol.notifications
  .map((method) => `  '${method}',`)
  .join("\n");

const dartAgentMessageTypes = (agentProtocol?.messageTypes ?? [])
  .map((messageType) => `  '${messageType}',`)
  .join("\n");
const dartAgentBaseFields = (agentProtocol?.baseEnvelopeFields ?? [])
  .map((field) => `  '${field}',`)
  .join("\n");
const dartAgentAssignmentFields = (
  agentProtocol?.assignmentEnvelopeFields ?? []
)
  .map((field) => `  '${field}',`)
  .join("\n");

const dart = `// GENERATED FILE. Do not edit by hand.

const protocolName = '${protocolName}';
const protocolVersion = '${protocolVersion}';
const requiredEnvelopeFields = <String>[
${dartFields}
];
const protocolMessageTypes = <String>{
${dartMessageTypes}
};
const protocolMessagePayloadSchemas = <String, String>{
${dartPayloads}
};

const hostProtocolName = '${hostProtocol.name}';
const hostProtocolVersion = '${hostProtocol.version}';
const hostProtocolMaxMessageSizeBytes = ${hostProtocol.maxMessageSizeBytes};
const hostProtocolMessageTypes = <String>{
${dartHostMessageTypes}
};
const hostProtocolBaseEnvelopeFields = <String>[
${dartHostBaseFields}
];
const hostProtocolAssignmentEnvelopeFields = <String>[
${dartHostAssignmentFields}
];

const agentProtocolName = '${agentProtocol?.name ?? "conclave.agent-protocol"}';
const agentProtocolVersion = '${agentProtocol?.version ?? "2.0"}';
const agentProtocolMaxMessageSizeBytes = ${agentProtocol?.maxMessageSizeBytes ?? 4194304};
const agentProtocolMessageTypes = <String>{
${dartAgentMessageTypes}
};
const agentProtocolBaseEnvelopeFields = <String>[
${dartAgentBaseFields}
];
const agentProtocolAssignmentEnvelopeFields = <String>[
${dartAgentAssignmentFields}
];
`;
const dartIpcCommands = (localProtocols?.agentAppIpc?.commandTypes ?? [])
  .map((type) => `  '${type}',`)
  .join("\n");
const dartPluginMethods = (localProtocols?.workerPlugin?.methods ?? [])
  .map((method) => `  '${method}',`)
  .join("\n");
const dartPluginNotifications = (
  localProtocols?.workerPlugin?.notifications ?? []
)
  .map((method) => `  '${method}',`)
  .join("\n");
const dartLocal = `// GENERATED FILE. Do not edit by hand.

const workerProtocolName = '${workerProtocol.name}';
const workerProtocolVersion = '${workerProtocol.version}';
const workerProtocolJsonRpcVersion = '${workerProtocol.jsonRpcVersion}';
const workerProtocolMethods = <String>{
${dartWorkerMethods}
};
const workerProtocolNotifications = <String>{
${dartWorkerNotifications}
};

const agentAppIpcProtocolName = '${localProtocols?.agentAppIpc?.name ?? "conclave.agent-app-ipc"}';
const agentAppIpcProtocolVersion = '${localProtocols?.agentAppIpc?.version ?? "1.0"}';
const agentAppIpcMaxFrameBytes = ${localProtocols?.agentAppIpc?.maxFrameBytes ?? 1048576};
const agentAppIpcCommandTypes = <String>{
${dartIpcCommands}
};
const workerPluginProtocolName = '${localProtocols?.workerPlugin?.name ?? "conclave.worker-plugin"}';
const workerPluginProtocolVersion = '${localProtocols?.workerPlugin?.version ?? "2.0"}';
const workerPluginJsonRpcVersion = '${localProtocols?.workerPlugin?.jsonRpcVersion ?? "2.0"}';
const workerPluginMethods = <String>{
${dartPluginMethods}
};
const workerPluginNotifications = <String>{
${dartPluginNotifications}
};
`;

await writeFile("packages/protocol/src/generated.ts", ts);
await writeFile("packages/agent-protocol/src/generated.ts", hostTs);
await writeFile("packages/protocol/src/generated-local-protocols.ts", localTs);
await writeFile(
  "packages/dart/protocol/lib/generated_local_protocols.dart",
  dartLocal,
);
await writeFile("packages/dart/protocol/lib/generated_protocol.dart", dart);
