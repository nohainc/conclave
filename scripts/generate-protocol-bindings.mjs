import { readFile, writeFile } from "node:fs/promises";

const schema = JSON.parse(
  await readFile(
    "packages/protocol/schema/conclave-message.schema.json",
    "utf8",
  ),
);
const host = schema["x-host-protocol"];
const realtime = schema["x-realtime-events"];
const messageTypes = schema["x-message-types"];
const payloads = schema["x-message-payloads"];
const errorCodes = schema["x-execution-error-codes"];
const errorMessages = schema["x-execution-error-messages"];

if (
  !host ||
  !realtime ||
  !Array.isArray(messageTypes) ||
  !Array.isArray(errorCodes) ||
  !payloads ||
  !errorMessages ||
  Object.hasOwn(schema, "x-agent-protocol") ||
  Object.hasOwn(schema, "x-local-protocols") ||
  Object.hasOwn(schema, "x-worker-protocol")
) {
  throw new Error(
    "current protocol schema metadata is incomplete or contains retired protocols",
  );
}

const jsonItems = (items) =>
  items.map((item) => `  ${JSON.stringify(item)},`).join("\n");
const dartItems = (items) =>
  items.map((item) => `  '${String(item).replaceAll("'", "\\'")}',`).join("\n");
const tsMessages = messageTypes
  .map((type) => `  ${type}: ${JSON.stringify(payloads[type])},`)
  .join("\n");
const tsErrors = errorCodes
  .map(
    (code) =>
      `  ${JSON.stringify(code)}: ${JSON.stringify(errorMessages[code])},`,
  )
  .join("\n");

const protocolTs = `// GENERATED FILE. Do not edit by hand.

export const PROTOCOL_NAME = ${JSON.stringify(schema.properties.protocol.const)} as const;
export const PROTOCOL_VERSION = ${JSON.stringify(schema["x-protocol-version"])} as const;
export const EXECUTION_ERROR_CODES = [
${jsonItems(errorCodes)}
] as const;
export const EXECUTION_ERROR_MESSAGES = {
${tsErrors}
} as const;
export const REQUIRED_ENVELOPE_FIELDS = [
${jsonItems(schema.required)}
] as const;
export const PROTOCOL_MESSAGE_TYPES = [
${jsonItems(messageTypes)}
] as const;
export const PROTOCOL_MESSAGE_PAYLOAD_SCHEMAS = {
${tsMessages}
} as const;

${hostTsConstants(host)}
${realtimeTsConstants(realtime)}
`;

const hostTs = `// GENERATED FILE. Do not edit by hand.

${hostTsConstants(host)}
${realtimeTsConstants(realtime)}
`;

const dartProtocol = `// GENERATED FILE. Do not edit by hand.

const protocolName = '${schema.properties.protocol.const}';
const protocolVersion = '${schema["x-protocol-version"]}';
const executionErrorCodes = <String>{
${dartItems(errorCodes)}
};
const executionErrorMessages = <String, String>{
${errorCodes.map((code) => `  '${code}': '${String(errorMessages[code]).replaceAll("'", "\\'")}',`).join("\n")}
};
const requiredEnvelopeFields = <String>[
${dartItems(schema.required)}
];
const protocolMessageTypes = <String>{
${dartItems(messageTypes)}
};
const protocolMessagePayloadSchemas = <String, String>{
  ${messageTypes.map((type) => `  '${type}': '${payloads[type].replaceAll("$", "\\$")}',`).join("\n")}
};

${hostDartConstants(host)}
${realtimeDartConstants(realtime)}
`;

await writeFile("packages/protocol/src/generated.ts", protocolTs);
await writeFile("packages/host-protocol/src/generated.ts", hostTs);
await writeFile(
  "packages/dart/protocol/lib/generated_protocol.dart",
  dartProtocol,
);

function hostTsConstants(value) {
  return `export const HOST_PROTOCOL_NAME = ${JSON.stringify(value.name)} as const;
export const HOST_PROTOCOL_VERSION = ${JSON.stringify(value.version)} as const;
export const HOST_PROTOCOL_MAX_MESSAGE_SIZE_BYTES = ${value.maxMessageSizeBytes} as const;
export const HOST_PROTOCOL_MESSAGE_TYPES = [
${jsonItems(value.messageTypes)}
] as const;
export const HOST_PROTOCOL_BASE_ENVELOPE_FIELDS = [
${jsonItems(value.baseEnvelopeFields)}
] as const;
export const HOST_PROTOCOL_ASSIGNMENT_ENVELOPE_FIELDS = [
${jsonItems(value.assignmentEnvelopeFields)}
] as const;`;
}

function realtimeTsConstants(value) {
  return `export const REALTIME_EVENTS_NAME = ${JSON.stringify(value.name)} as const;
export const REALTIME_EVENTS_VERSION = ${JSON.stringify(value.version)} as const;
export const REALTIME_EVENT_ENVELOPE_FIELDS = [
${jsonItems(value.envelopeFields)}
] as const;
export const REALTIME_EVENT_OPTIONAL_ENVELOPE_FIELDS = [
${jsonItems(value.optionalEnvelopeFields)}
] as const;
export const DURABLE_REALTIME_EVENT_TYPES = [
${jsonItems(value.durableTypes)}
] as const;
export const EPHEMERAL_REALTIME_EVENT_TYPES = [
${jsonItems(value.ephemeralTypes)}
] as const;
export const REALTIME_EVENT_PAYLOAD_SCHEMA = ${JSON.stringify(value.payloadSchema)} as const;`;
}

function hostDartConstants(value) {
  return `const hostProtocolName = '${value.name}';
const hostProtocolVersion = '${value.version}';
const hostProtocolMaxMessageSizeBytes = ${value.maxMessageSizeBytes};
const hostProtocolMessageTypes = <String>{
${dartItems(value.messageTypes)}
};
const hostProtocolBaseEnvelopeFields = <String>[
${dartItems(value.baseEnvelopeFields)}
];
const hostProtocolAssignmentEnvelopeFields = <String>[
${dartItems(value.assignmentEnvelopeFields)}
];`;
}

function realtimeDartConstants(value) {
  return `const realtimeEventsName = '${value.name}';
const realtimeEventsVersion = '${value.version}';
const realtimeEventEnvelopeFields = <String>[
${dartItems(value.envelopeFields)}
];
const realtimeEventOptionalEnvelopeFields = <String>[
${dartItems(value.optionalEnvelopeFields)}
];
const durableRealtimeEventTypes = <String>{
${dartItems(value.durableTypes)}
};
const ephemeralRealtimeEventTypes = <String>{
${dartItems(value.ephemeralTypes)}
};
const realtimeEventPayloadSchema = '${value.payloadSchema.replaceAll("$", "\\$")}';`;
}
