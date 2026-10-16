import {
  EXECUTION_ERROR_CODES,
  EXECUTION_ERROR_MESSAGES,
} from "./generated.js";

export {
  EXECUTION_ERROR_CODES,
  EXECUTION_ERROR_MESSAGES,
} from "./generated.js";
export {
  COLLABORATION_REALTIME_EVENT_TYPES,
  REALTIME_STREAM_KINDS,
} from "./generated.js";
export * from "./realtime-events.js";
export * from "./execution-permissions.js";
export * from "./worker-descriptor.js";
export * from "./diagnostic-events.js";
export * from "./execution-events.js";
export * from "./execution-activity.js";

export type ExecutionErrorCode = (typeof EXECUTION_ERROR_CODES)[number];

export function isExecutionErrorCode(
  value: unknown,
): value is ExecutionErrorCode {
  return (
    typeof value === "string" &&
    (EXECUTION_ERROR_CODES as readonly string[]).includes(value)
  );
}

export function canonicalExecutionErrorCode(
  value: unknown,
): ExecutionErrorCode {
  // These fixed Conclave errors can already be stored on tasks that failed
  // before assignment creation. Never expose arbitrary diagnostic text.
  if (
    typeof value === "string" &&
    [
      "Context exceeds the byte limit",
      "Conversation bootstrap exceeds the history or byte limit",
      "Conversation bootstrap exceeds the history limit",
      "Conversation bootstrap exceeds the byte limit",
      "Conversation context exceeds the supported history or 256 KiB serialized byte limit. Start a new Thread with the relevant context before retrying.",
    ].includes(value)
  )
    return "context_limit_exceeded";
  return isExecutionErrorCode(value) ? value : "execution_failed";
}

export function executionErrorMessage(code: ExecutionErrorCode): string {
  return EXECUTION_ERROR_MESSAGES[code];
}
