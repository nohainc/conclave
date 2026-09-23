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
  "worker.install",
  "worker.remove",
  "worker.status",
  "credential.status",
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

export const WORKER_PROTOCOL_NAME = "conclave.worker-protocol" as const;
export const WORKER_PROTOCOL_VERSION = "4.0" as const;
export const WORKER_PROTOCOL_JSON_RPC_VERSION = "2.0" as const;
export const WORKER_PROTOCOL_METHODS = [
  "initialize",
  "health",
  "describe",
  "execute",
  "cancel",
  "shutdown",
] as const;
export const WORKER_PROTOCOL_NOTIFICATIONS = [
  "progress",
  "status",
  "output_delta",
  "tool.started",
  "tool.completed",
  "usage",
  "artifact",
  "result",
  "error",
  "log",
] as const;

export const REALTIME_EVENTS_NAME = "conclave.realtime-events" as const;
export const REALTIME_EVENTS_VERSION = "1.0" as const;
export const REALTIME_EVENT_ENVELOPE_FIELDS = [
  "eventId",
  "type",
  "version",
  "timestamp",
  "workspaceId",
  "sequence",
  "payload",
] as const;
export const REALTIME_EVENT_OPTIONAL_ENVELOPE_FIELDS = [
  "projectId",
  "chatId",
  "runId",
  "taskId",
  "attemptId",
  "assignmentId",
  "hostId",
] as const;
export const DURABLE_REALTIME_EVENT_TYPES = [
  "chat.message.created",
  "run.started",
  "run.paused",
  "run.resumed",
  "run.completed",
  "run.failed",
  "task.started",
  "task.completed",
  "task.failed",
  "attempt.started",
  "attempt.completed",
  "attempt.failed",
  "assignment.accepted",
  "assignment.completed",
  "assignment.failed",
  "assignment.cancelled",
  "artifact.created",
  "finding.created",
  "finding.resolved",
  "verification.completed",
  "host.enrolled",
  "host.revoked",
  "account.sharing.changed",
] as const;
export const EPHEMERAL_REALTIME_EVENT_TYPES = [
  "assignment.progress",
  "worker.status",
  "stream.delta",
  "tool.invocation.status",
  "typing",
  "heartbeat",
  "host.load",
] as const;
export const REALTIME_EVENT_PAYLOAD_SCHEMA =
  "#/$defs/realtimeEventPayload" as const;

export const AGENT_PROTOCOL_NAME = "conclave.agent-protocol" as const;
export const AGENT_PROTOCOL_VERSION = "2.0" as const;
export const AGENT_PROTOCOL_MAX_MESSAGE_SIZE_BYTES = 4194304 as const;
export const AGENT_PROTOCOL_MESSAGE_TYPES = [
  "agent.hello",
  "agent.hello.ack",
  "agent.heartbeat",
  "agent.heartbeat.ack",
  "agent.sync.request",
  "agent.sync.response",
  "agent.capabilities",
  "agent.update.available",
  "agent.update.status",
  "plugin.install",
  "plugin.update",
  "plugin.remove",
  "plugin.status",
  "worker.configure",
  "worker.status",
  "assignment.start",
  "assignment.ack",
  "assignment.progress",
  "assignment.result",
  "assignment.error",
  "assignment.cancelled",
  "assignment.cancel",
  "assignment.cancel.ack",
] as const;
export const AGENT_PROTOCOL_BASE_ENVELOPE_FIELDS = [
  "protocol",
  "protocolVersion",
  "messageId",
  "correlationId",
  "timestamp",
  "type",
  "payload",
] as const;
export const AGENT_PROTOCOL_ASSIGNMENT_ENVELOPE_FIELDS = [
  "workspaceId",
  "agentId",
  "workerId",
  "runId",
  "taskId",
  "attemptId",
  "assignmentId",
  "idempotencyKey",
] as const;
