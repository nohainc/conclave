import { expect, it } from "vitest";
import { workStepSessionKey } from "../src/work-session-key.js";

it("uses Engine-safe opaque keys and preserves the Direct conversation across requests", () => {
  const params = {
    workBindingId: "direct" as const,
    workstreamId: "workstream-1",
    workRequestId: "request-1",
    stepKind: "implement",
  };
  const key = workStepSessionKey(params);
  expect(key).toMatch(/^[A-Za-z0-9_-]+$/);
  expect(key.length).toBeLessThanOrEqual(256);
  expect(workStepSessionKey({ ...params, workRequestId: "request-2" })).toBe(
    key,
  );
  expect(
    workStepSessionKey({ ...params, workstreamId: "workstream-2" }),
  ).not.toBe(key);
  expect(
    workStepSessionKey({
      ...params,
      retryStepKind: "implement",
      retrySessionStrategy: "continue",
      retryNumber: 1,
    }),
  ).toBe(key);
  expect(
    workStepSessionKey({
      ...params,
      retryStepKind: "implement",
      retrySessionStrategy: "fresh",
      retryNumber: 1,
    }),
  ).not.toBe(key);
});

it("isolates non-Direct sessions by request and Step", () => {
  const params = {
    workstreamId: "workstream-1",
    workRequestId: "request-1",
    stepKind: "implement",
  };
  const key = workStepSessionKey(params);
  expect(
    workStepSessionKey({ ...params, workRequestId: "request-2" }),
  ).not.toBe(key);
  expect(workStepSessionKey({ ...params, stepKind: "verify" })).not.toBe(key);
});
