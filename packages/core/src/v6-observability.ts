/** V6 audit and Workstream iteration observability contracts. */

export const V6_AUDIT_ACTIONS = [
  "discussion.moderated",
  "work_request.created",
  "workflow.selected",
  "account.selected",
  "checkout.provisioned",
  "checkout.recovered",
  "lease.acquired",
  "lease.released",
  "checkpoint.created",
  "integration.updated",
  "worker.created",
  "worker.updated",
  "worker.revoked",
  "worker.workspace.bound",
  "worker.workspace.unbound",
  "worker.credential.setup_requested",
  "worker.credential.ready",
  "worker.credential.revoked",
] as const;
export type V6AuditAction = (typeof V6_AUDIT_ACTIONS)[number];

export interface V6AuditRecord {
  readonly projectId: string;
  readonly workstreamId: string;
  readonly workRequestId?: string;
  readonly actorId: string;
  readonly action: V6AuditAction;
  readonly targetId: string;
  readonly details: Readonly<Record<string, unknown>>;
  readonly occurredAt: string;
}

export interface V6ObservabilitySample {
  readonly queueEnteredAt?: string;
  readonly startedAt?: string;
  readonly finishedAt?: string;
  readonly checkoutRecoveryAttempted?: boolean;
  readonly checkoutRecoverySucceeded?: boolean;
  readonly rollbackAttempted?: boolean;
  readonly rollbackSucceeded?: boolean;
  readonly workspaceId: string;
  readonly activeAtSample: boolean;
}

export interface V6ObservabilityMetrics {
  readonly queueWaitMs: number;
  readonly statefulDurationMs: number;
  readonly checkoutRecoveryRate: number;
  readonly failedRollbackRate: number;
  readonly workspaceUtilization: number;
}

export interface V6ConfiguredWorkerMetric {
  readonly configuredWorkerId: string;
  readonly workerTypeId: string;
  readonly workspaceId?: string;
  readonly ready: boolean;
  readonly packageStatus: string;
  readonly credentialStatus: string;
  readonly permissionsStatus: string;
  readonly activeAssignments: number;
  readonly authFailure: boolean;
  readonly convergenceLatencyMs?: number;
  readonly recordedAt: string;
}

function elapsed(start?: string, end?: string): number {
  if (!start || !end) return 0;
  const value = Date.parse(end) - Date.parse(start);
  return Number.isFinite(value) && value >= 0 ? value : 0;
}

export function computeV6ObservabilityMetrics(
  samples: readonly V6ObservabilitySample[],
): V6ObservabilityMetrics {
  const recoverySamples = samples.filter(
    (sample) => sample.checkoutRecoveryAttempted,
  );
  const rollbackSamples = samples.filter((sample) => sample.rollbackAttempted);
  const activeSamples = samples.filter((sample) => sample.activeAtSample);
  return {
    queueWaitMs: samples.reduce(
      (sum, sample) => sum + elapsed(sample.queueEnteredAt, sample.startedAt),
      0,
    ),
    statefulDurationMs: samples.reduce(
      (sum, sample) => sum + elapsed(sample.startedAt, sample.finishedAt),
      0,
    ),
    checkoutRecoveryRate:
      recoverySamples.length === 0
        ? 0
        : recoverySamples.filter((sample) => sample.checkoutRecoverySucceeded)
            .length / recoverySamples.length,
    failedRollbackRate:
      rollbackSamples.length === 0
        ? 0
        : rollbackSamples.filter((sample) => !sample.rollbackSucceeded).length /
          rollbackSamples.length,
    workspaceUtilization:
      samples.length === 0 ? 0 : activeSamples.length / samples.length,
  };
}
