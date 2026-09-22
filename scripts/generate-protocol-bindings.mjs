import { readFile, writeFile } from "node:fs/promises";

const schemaPath = "packages/protocol/schema/conclave-message.schema.json";
const schema = JSON.parse(await readFile(schemaPath, "utf8"));
const protocolName = schema.properties.protocol.const;
const protocolVersion = schema["x-protocol-version"];
const messageTypes = schema["x-message-types"];
const messagePayloads = schema["x-message-payloads"];
const requiredFields = schema.required;
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
  typeof agentProtocol !== "object" ||
  agentProtocol === null ||
  typeof agentProtocol.name !== "string" ||
  typeof agentProtocol.version !== "string" ||
  typeof agentProtocol.maxMessageSizeBytes !== "number" ||
  !Array.isArray(agentProtocol.messageTypes) ||
  !Array.isArray(agentProtocol.baseEnvelopeFields) ||
  !Array.isArray(agentProtocol.assignmentEnvelopeFields) ||
  typeof localProtocols !== "object" ||
  localProtocols === null ||
  typeof localProtocols.agentAppIpc !== "object" ||
  typeof localProtocols.workerPlugin !== "object"
) {
  throw new Error("canonical protocol schema is missing generator metadata");
}

const agentMessageTypes = agentProtocol.messageTypes
  .map((messageType) => `  ${JSON.stringify(messageType)},`)
  .join("\n");
const agentBaseFields = agentProtocol.baseEnvelopeFields
  .map((field) => `  ${JSON.stringify(field)},`)
  .join("\n");
const agentAssignmentFields = agentProtocol.assignmentEnvelopeFields
  .map((field) => `  ${JSON.stringify(field)},`)
  .join("\n");
const ipcCommandTypes = localProtocols.agentAppIpc.commandTypes
  .map((type) => `  ${JSON.stringify(type)},`)
  .join("\n");
const pluginMethods = localProtocols.workerPlugin.methods
  .map((method) => `  ${JSON.stringify(method)},`)
  .join("\n");
const pluginNotifications = localProtocols.workerPlugin.notifications
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
const ts = `// GENERATED FILE. Do not edit by hand.\n\nexport const PROTOCOL_NAME = ${JSON.stringify(protocolName)} as const;\nexport const PROTOCOL_VERSION = ${JSON.stringify(protocolVersion)} as const;\nexport const REQUIRED_ENVELOPE_FIELDS = [\n${tsFields}\n] as const;\nexport const PROTOCOL_MESSAGE_TYPES = [\n${tsMessageTypes}\n] as const;\nexport const PROTOCOL_MESSAGE_PAYLOAD_SCHEMAS = {\n${tsPayloads}\n} as const;\nexport const AGENT_PROTOCOL_NAME = ${JSON.stringify(agentProtocol.name)} as const;\nexport const AGENT_PROTOCOL_VERSION = ${JSON.stringify(agentProtocol.version)} as const;\nexport const AGENT_PROTOCOL_MAX_MESSAGE_SIZE_BYTES = ${agentProtocol.maxMessageSizeBytes} as const;\nexport const AGENT_PROTOCOL_MESSAGE_TYPES = [\n${agentMessageTypes}\n] as const;\nexport const AGENT_PROTOCOL_BASE_ENVELOPE_FIELDS = [\n${agentBaseFields}\n] as const;\nexport const AGENT_PROTOCOL_ASSIGNMENT_ENVELOPE_FIELDS = [\n${agentAssignmentFields}\n] as const;\n`;
const agentTs = `// GENERATED FILE. Do not edit by hand.\n\nexport const AGENT_PROTOCOL_NAME = ${JSON.stringify(agentProtocol.name)} as const;\nexport const AGENT_PROTOCOL_VERSION = ${JSON.stringify(agentProtocol.version)} as const;\nexport const AGENT_PROTOCOL_MAX_MESSAGE_SIZE_BYTES = ${agentProtocol.maxMessageSizeBytes} as const;\nexport const AGENT_PROTOCOL_MESSAGE_TYPES = [\n${agentMessageTypes}\n] as const;\nexport const AGENT_PROTOCOL_BASE_ENVELOPE_FIELDS = [\n${agentBaseFields}\n] as const;\nexport const AGENT_PROTOCOL_ASSIGNMENT_ENVELOPE_FIELDS = [\n${agentAssignmentFields}\n] as const;\n`;
const localTs = `// GENERATED FILE. Do not edit by hand.\n\nexport const AGENT_APP_IPC_PROTOCOL_NAME = ${JSON.stringify(localProtocols.agentAppIpc.name)} as const;\nexport const AGENT_APP_IPC_PROTOCOL_VERSION = ${JSON.stringify(localProtocols.agentAppIpc.version)} as const;\nexport const AGENT_APP_IPC_MAX_FRAME_BYTES = ${localProtocols.agentAppIpc.maxFrameBytes} as const;\nexport const AGENT_APP_IPC_COMMAND_TYPES = [\n${ipcCommandTypes}\n] as const;\nexport const WORKER_PLUGIN_PROTOCOL_NAME = ${JSON.stringify(localProtocols.workerPlugin.name)} as const;\nexport const WORKER_PLUGIN_PROTOCOL_VERSION = ${JSON.stringify(localProtocols.workerPlugin.version)} as const;\nexport const WORKER_PLUGIN_JSON_RPC_VERSION = ${JSON.stringify(localProtocols.workerPlugin.jsonRpcVersion)} as const;\nexport const WORKER_PLUGIN_METHODS = [\n${pluginMethods}\n] as const;\nexport const WORKER_PLUGIN_NOTIFICATIONS = [\n${pluginNotifications}\n] as const;\n`;
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
const dartAgentMessageTypes = agentProtocol.messageTypes
  .map((messageType) => `  '${messageType}',`)
  .join("\n");
const dartAgentBaseFields = agentProtocol.baseEnvelopeFields
  .map((field) => `  '${field}',`)
  .join("\n");
const dartAgentAssignmentFields = agentProtocol.assignmentEnvelopeFields
  .map((field) => `  '${field}',`)
  .join("\n");
const dart = `// GENERATED FILE. Do not edit by hand.\n\nconst protocolName = '${protocolName}';\nconst protocolVersion = '${protocolVersion}';\nconst requiredEnvelopeFields = <String>[\n${dartFields}\n];\nconst protocolMessageTypes = <String>{\n${dartMessageTypes}\n};\nconst protocolMessagePayloadSchemas = <String, String>{\n${dartPayloads}\n};\nconst agentProtocolName = '${agentProtocol.name}';\nconst agentProtocolVersion = '${agentProtocol.version}';\nconst agentProtocolMaxMessageSizeBytes = ${agentProtocol.maxMessageSizeBytes};\nconst agentProtocolMessageTypes = <String>{\n${dartAgentMessageTypes}\n};\nconst agentProtocolBaseEnvelopeFields = <String>[\n${dartAgentBaseFields}\n];\nconst agentProtocolAssignmentEnvelopeFields = <String>[\n${dartAgentAssignmentFields}\n];\n`;
const dartIpcCommands = localProtocols.agentAppIpc.commandTypes
  .map((type) => `  '${type}',`)
  .join("\n");
const dartPluginMethods = localProtocols.workerPlugin.methods
  .map((method) => `  '${method}',`)
  .join("\n");
const dartPluginNotifications = localProtocols.workerPlugin.notifications
  .map((method) => `  '${method}',`)
  .join("\n");
const dartLocal = `// GENERATED FILE. Do not edit by hand.\n\nconst agentAppIpcProtocolName = '${localProtocols.agentAppIpc.name}';\nconst agentAppIpcProtocolVersion = '${localProtocols.agentAppIpc.version}';\nconst agentAppIpcMaxFrameBytes = ${localProtocols.agentAppIpc.maxFrameBytes};\nconst agentAppIpcCommandTypes = <String>{\n${dartIpcCommands}\n};\nconst workerPluginProtocolName = '${localProtocols.workerPlugin.name}';\nconst workerPluginProtocolVersion = '${localProtocols.workerPlugin.version}';\nconst workerPluginJsonRpcVersion = '${localProtocols.workerPlugin.jsonRpcVersion}';\nconst workerPluginMethods = <String>{\n${dartPluginMethods}\n};\nconst workerPluginNotifications = <String>{\n${dartPluginNotifications}\n};\n`;

await writeFile("packages/protocol/src/generated.ts", ts);
await writeFile("packages/agent-protocol/src/generated.ts", agentTs);
await writeFile("packages/protocol/src/generated-local-protocols.ts", localTs);
await writeFile("packages/dart/protocol/lib/generated_local_protocols.dart", dartLocal);
await writeFile("packages/dart/protocol/lib/generated_protocol.dart", dart);
