// GENERATED FILE. Do not edit by hand.

export const HOST_PROTOCOL_NAME = "conclave.host-protocol" as const;
export const HOST_PROTOCOL_VERSION = "4.0" as const;
export const HOST_PROTOCOL_MAX_MESSAGE_SIZE_BYTES = 4194304 as const;
export const HOST_PROTOCOL_MESSAGE_TYPES = [
  "host.hello",
  "host.hello.ack",
  "host.heartbeat",
  "host.heartbeat.ack",
  "host.sync.request",
  "host.sync.result",
  "host.status",
  "host.update",
  "assignment.start",
  "assignment.ack",
  "assignment.progress",
  "assignment.result",
  "assignment.error",
  "assignment.cancel",
  "assignment.cancel.ack",
] as const;
export const HOST_PROTOCOL_BASE_ENVELOPE_FIELDS = [
  "protocol",
  "protocolVersion",
  "messageId",
  "correlationId",
  "timestamp",
  "type",
  "payload",
] as const;
export const HOST_PROTOCOL_ASSIGNMENT_ENVELOPE_FIELDS = [
  "workspaceId",
  "hostId",
  "workerId",
  "runId",
  "taskId",
  "attemptId",
  "assignmentId",
  "idempotencyKey",
] as const;
