// GENERATED FILE. Do not edit by hand.

export const PROTOCOL_NAME = "conclave.protocol" as const;
export const PROTOCOL_VERSION = "0.1" as const;
export const REQUIRED_ENVELOPE_FIELDS = [
  "protocol",
  "version",
  "messageId",
  "goalId",
  "runId",
  "workerId",
  "createdAt",
  "messageType",
  "payload",
] as const;
export const PROTOCOL_MESSAGE_TYPES = [
  "PlanRequest",
  "PlanResult",
  "TaskRequest",
  "TaskResult",
  "ResearchResult",
  "ImplementationResult",
  "ReviewResult",
  "TestResult",
  "VerificationResult",
  "DecisionResult",
  "CompletionResult",
  "RuntimeOperationRequest",
] as const;
export const PROTOCOL_MESSAGE_PAYLOAD_SCHEMAS = {
  PlanRequest: "#/$defs/planRequestPayload",
  PlanResult: "#/$defs/planResultPayload",
  TaskRequest: "#/$defs/taskRequestPayload",
  TaskResult: "#/$defs/taskResultPayload",
  ResearchResult: "#/$defs/researchResultPayload",
  ImplementationResult: "#/$defs/implementationResultPayload",
  ReviewResult: "#/$defs/reviewResultPayload",
  TestResult: "#/$defs/testResultPayload",
  VerificationResult: "#/$defs/verificationResultPayload",
  DecisionResult: "#/$defs/decisionResultPayload",
  CompletionResult: "#/$defs/completionResultPayload",
  RuntimeOperationRequest: "#/$defs/runtimeOperationPayload",
} as const;

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
