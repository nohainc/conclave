import {
  EXECUTION_ERROR_CODES,
  EXECUTION_ERROR_MESSAGES,
} from "./generated.js";

export {
  EXECUTION_ERROR_CODES,
  EXECUTION_ERROR_MESSAGES,
} from "./generated.js";
export * from "./realtime-events.js";
export * from "./execution-permissions.js";

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
  return isExecutionErrorCode(value) ? value : "execution_failed";
}

export function executionErrorMessage(code: ExecutionErrorCode): string {
  return EXECUTION_ERROR_MESSAGES[code];
}
