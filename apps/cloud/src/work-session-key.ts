import { createHash } from "node:crypto";
import type { ThreadBindingId } from "@conclave/core";

export function workStepSessionKey(params: {
  readonly workBindingId?: ThreadBindingId;
  readonly threadId: string;
  readonly workRequestId: string;
  readonly stepKind: string;
  readonly retryStepKind?: unknown;
  readonly retrySessionStrategy?: unknown;
  readonly retryNumber?: unknown;
}): string {
  const base =
    params.workBindingId === "direct"
      ? `thread:${params.threadId}:direct:work-conversation`
      : params.workBindingId === "chat"
        ? `thread:${params.threadId}:chat:conversation`
        : `work-request:${params.workRequestId}:${params.stepKind}`;
  const identity =
    params.retryStepKind === params.stepKind &&
    params.retrySessionStrategy === "fresh"
      ? `${base}:retry-fresh-${Number(params.retryNumber) || 1}`
      : base;
  return `work-session-${createHash("sha256").update(identity).digest("hex")}`;
}
