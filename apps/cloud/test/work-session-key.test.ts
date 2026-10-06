import { expect, it } from "vitest";
import { createHash } from "node:crypto";
import { workStepSessionKey } from "../src/work-session-key.js";

it("uses Engine-safe opaque keys and preserves the Work/direct conversation across requests", () => {
  const params = {
    workBindingId: "direct" as const,
    workstreamId: "workstream-1",
    workRequestId: "request-1",
    stepKind: "implement",
  };
  const key = workStepSessionKey(params);
  expect(key).toBe(
    `work-session-${createHash("sha256").update("workstream:workstream-1:direct:work-conversation").digest("hex")}`,
  );
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

it("keeps Chat durable within a Workstream and isolated from Work", () => {
  const params = {
    workBindingId: "chat" as const,
    workstreamId: "workstream-1",
    workRequestId: "request-1",
    stepKind: "chat",
  };
  const key = workStepSessionKey(params);
  expect(key).toBe(
    `work-session-${createHash("sha256").update("workstream:workstream-1:chat:conversation").digest("hex")}`,
  );
  for (const workRequestId of ["request-2", "request-3"]) {
    expect(workStepSessionKey({ ...params, workRequestId })).toBe(key);
  }
  expect(
    workStepSessionKey({ ...params, workstreamId: "workstream-2" }),
  ).not.toBe(key);
  expect(
    workStepSessionKey({
      ...params,
      workBindingId: "direct",
      stepKind: "implement",
    }),
  ).not.toBe(key);
  expect(
    workStepSessionKey({
      ...params,
      retryStepKind: "chat",
      retrySessionStrategy: "continue",
    }),
  ).toBe(key);
  expect(
    workStepSessionKey({
      ...params,
      retryStepKind: "chat",
      retrySessionStrategy: "fresh",
      retryNumber: 1,
    }),
  ).not.toBe(key);
});

it.each(["research", "plan", "implement", "test", "verify"])(
  "isolates %s sessions by request and Step",
  (stepKind) => {
    const params = {
      workstreamId: "workstream-1",
      workRequestId: "request-1",
      stepKind,
    };
    const key = workStepSessionKey(params);
    expect(
      workStepSessionKey({ ...params, workRequestId: "request-2" }),
    ).not.toBe(key);
    expect(workStepSessionKey({ ...params, stepKind: "other-step" })).not.toBe(
      key,
    );
  },
);
