import { describe, expect, it } from "vitest";
import {
  EXECUTION_ERROR_CODES,
  EXECUTION_ERROR_MESSAGES,
  canonicalExecutionErrorCode,
  executionErrorMessage,
  isExecutionErrorCode,
} from "../src/index.js";

describe("canonical execution error taxonomy", () => {
  it("has one safe display message for every stable code", () => {
    expect(Object.keys(EXECUTION_ERROR_MESSAGES).sort()).toEqual(
      [...EXECUTION_ERROR_CODES].sort(),
    );
    for (const code of EXECUTION_ERROR_CODES) {
      expect(executionErrorMessage(code)).toBeTruthy();
    }
  });

  it("normalizes unknown implementation errors to a generic failure", () => {
    expect(isExecutionErrorCode("permission_denied")).toBe(true);
    expect(isExecutionErrorCode("tool_permission_denied")).toBe(false);
    expect(canonicalExecutionErrorCode("codex_cli_error")).toBe(
      "execution_failed",
    );
  });
});
