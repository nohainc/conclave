import { createHash } from "node:crypto";
import type { WorkstreamBindingId } from "@conclave/core";

export function workStepSessionKey(params: {
  readonly workBindingId?: WorkstreamBindingId;
  readonly workstreamId: string;
  readonly workRequestId: string;
  readonly stepKind: string;
  readonly retryStepKind?: unknown;
  readonly retrySessionStrategy?: unknown;
  readonly retryNumber?: unknown;
}): string {
  const base = params.workBindingId === "direct"
    ? `workstream:${params.workstreamId}:direct:work-conversation`
    : `work-request:${params.workRequestId}:${params.stepKind}`;
  const identity = params.retryStepKind === params.stepKind && params.retrySessionStrategy === "fresh"
    ? `${base}:retry-fresh-${Number(params.retryNumber) || 1}` : base;
  return `work-session-${createHash("sha256").update(identity).digest("hex")}`;
}
