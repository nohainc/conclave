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
  readonly workSessionGeneration?: number;
}): string {
  const base =
    params.workBindingId === "direct"
      ? `thread:${params.threadId}:direct:work-conversation${params.workSessionGeneration && params.workSessionGeneration > 0 ? `:gen-${params.workSessionGeneration}` : ""}`
      : params.workBindingId === "chat"
        ? `thread:${params.threadId}:chat:conversation${params.workSessionGeneration && params.workSessionGeneration > 0 ? `:gen-${params.workSessionGeneration}` : ""}`
        : `work-request:${params.workRequestId}:${params.stepKind}`;
  // A fresh retry of the Thread's own Work conversation bumps the Thread's
  // session generation instead (see handleRetryWorkRequest), so later requests
  // keep using the new session. Other scopes isolate the retry by suffix.
  const identity =
    params.retryStepKind === params.stepKind &&
    params.retrySessionStrategy === "fresh" &&
    params.workBindingId !== "direct" &&
    !(params.workBindingId === "chat" && params.workSessionGeneration)
      ? `${base}:retry-fresh-${Number(params.retryNumber) || 1}`
      : base;
  return `work-session-${createHash("sha256").update(identity).digest("hex")}`;
}
