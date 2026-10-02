// GENERATED FILE. Do not edit by hand.

export const PROTOCOL_NAME = "conclave.protocol" as const;
export const PROTOCOL_VERSION = "0.1" as const;
export const EXECUTION_ERROR_CODES = [
  "worker_not_ready",
  "cli_not_found",
  "authentication_required",
  "unsupported_cli_version",
  "model_not_supported",
  "permission_denied",
  "quota_exhausted",
  "provider_unavailable",
  "timeout",
  "cancelled",
  "internal_adapter_error",
  "execution_failed",
] as const;
export const EXECUTION_ERROR_MESSAGES = {
  "worker_not_ready": "The selected Worker is not ready on its Workspace.",
  "cli_not_found": "The required local CLI could not be found.",
  "authentication_required": "Sign in to the configured provider on this computer.",
  "unsupported_cli_version": "The installed local CLI version is not supported.",
  "model_not_supported": "The selected model is not supported by this Worker.",
  "permission_denied": "A local permission required for this assignment was denied.",
  "quota_exhausted": "The provider's usage limit has been reached.",
  "provider_unavailable": "The provider is temporarily unavailable.",
  "timeout": "The assignment exceeded its time limit.",
  "cancelled": "The assignment was cancelled.",
  "internal_adapter_error": "The local Worker integration needs attention.",
  "execution_failed": "The assignment could not be completed.",
} as const;
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
  "work_request.created",
  "work_request.started",
  "work_request.completed",
  "work_request.failed",
  "work_request.cancelled",
  "step.queued",
  "step.running",
  "step.completed",
  "step.failed",
  "step.cancelled",
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
export const REALTIME_EVENT_PAYLOAD_SCHEMA = "#/$defs/realtimeEventPayload" as const;
