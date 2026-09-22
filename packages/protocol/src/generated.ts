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
