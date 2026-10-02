const jsonArray = (value: unknown): string[] => {
  if (typeof value !== "string") return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed)
      ? parsed.filter((item): item is string => typeof item === "string")
      : [];
  } catch {
    return [];
  }
};

export function runtimeFacts(payload: unknown): {
  platform: string | null;
  architecture: string | null;
  hostname: string | null;
  appVersion: string | null;
  capabilities: string[];
} {
  if (!payload || typeof payload !== "object") {
    return {
      platform: null,
      architecture: null,
      hostname: null,
      appVersion: null,
      capabilities: [],
    };
  }
  const value = payload as Record<string, unknown>;
  const rawCapabilities =
    value.capabilities && typeof value.capabilities === "object"
      ? (value.capabilities as Record<string, unknown>)
      : {};
  const text = (candidate: unknown): string | null => {
    if (typeof candidate !== "string") return null;
    const normalized = candidate.trim();
    return normalized.length > 0 && normalized.length <= 200
      ? normalized
      : null;
  };
  const capabilities = Array.isArray(value.runtimeCapabilities)
    ? value.runtimeCapabilities
        .filter((item): item is string => typeof item === "string")
        .slice(0, 100)
    : [
        ...jsonArray(JSON.stringify(rawCapabilities.supportedRuntimes)),
        ...jsonArray(JSON.stringify(rawCapabilities.customCapabilities)),
      ];
  return {
    platform: text(value.platform ?? rawCapabilities.os),
    architecture: text(value.architecture ?? rawCapabilities.arch),
    hostname: text(value.hostname),
    appVersion: text(value.appVersion ?? rawCapabilities.version),
    capabilities: [
      ...new Set(capabilities.map((item) => item.trim()).filter(Boolean)),
    ],
  };
}

export function normalizeWorkspaceWorkerInstallationStatus(
  status: string,
):
  | "absent"
  | "requested"
  | "installing"
  | "ready"
  | "updating"
  | "degraded"
  | "failed"
  | "removing" {
  switch (status) {
    case "installed":
    case "active":
    case "ready":
      return "ready";
    case "requested":
      return "requested";
    case "downloading":
    case "verifying":
    case "installing":
      return "installing";
    case "updating":
      return "updating";
    case "removing":
      return "removing";
    case "absent":
      return "absent";
    case "degraded":
      return "degraded";
    case "failed":
      return "failed";
    default:
      return "failed";
  }
}

export interface WorkspaceGatewayEnv {
  CONCLAVE_DB: D1Database;
  CONCLAVE_REALTIME_GATEWAY?: DurableObjectNamespace;
}

export interface WorkspaceAssignmentCorrelation {
  executionWorkspaceId: string;
  workspaceRuntimeId: string;
  workerId: string;
  runId: string;
  taskId: string;
  attemptId: string;
  assignmentId: string;
  idempotencyKey: string;
}

export function workspaceAssignmentContextMatches(
  message: WorkspaceAssignmentCorrelation,
  row: Record<string, unknown>,
): boolean {
  return (
    message.executionWorkspaceId === String(row.execution_workspace_id) &&
    message.workspaceRuntimeId === String(row.runtime_identity_id) &&
    message.workerId ===
      String(row.workspace_worker_id ?? row.worker_type_id) &&
    message.runId === String(row.run_id) &&
    message.taskId === String(row.task_id) &&
    message.attemptId === String(row.attempt_id) &&
    message.assignmentId === String(row.id) &&
    message.idempotencyKey === String(row.idempotency_key)
  );
}

export function isCurrentWorkspaceSocket(
  currentSocket: WebSocket | null,
  currentSessionId: string | null,
  socket?: WebSocket,
  sessionId?: string | null,
): boolean {
  return (
    (!socket || currentSocket === socket) &&
    (!sessionId || currentSessionId === sessionId)
  );
}

export function workspaceAssignmentIsActive(
  row: Record<string, unknown>,
): boolean {
  return !["completed", "failed", "cancelled", "timed_out"].includes(
    String(row.status),
  );
}

export async function isWorkspaceRuntimeAuthorized(
  db: Pick<D1Database, "prepare">,
  workspaceRuntimeId: string,
  tokenHash: string,
): Promise<{ executionWorkspaceId: string } | null> {
  const row = await db
    .prepare(
      `SELECT wri.workspace_id AS executionWorkspaceId
       FROM workspace_runtime_identities wri
       JOIN execution_workspaces ew ON ew.id = wri.workspace_id
       WHERE wri.id = ?1
         AND wri.credential_token_hash = ?2
         AND wri.revoked_at IS NULL
         AND ew.status <> 'revoked'`,
    )
    .bind(workspaceRuntimeId, tokenHash)
    .first<{ executionWorkspaceId: string }>();
  return row ?? null;
}

export async function findWorkspaceRuntimeIdentity(
  db: Pick<D1Database, "prepare">,
  workspaceRuntimeId: string,
): Promise<{
  executionWorkspaceId: string;
  credentialTokenHash: string;
} | null> {
  const row = await db
    .prepare(
      `SELECT wri.workspace_id AS executionWorkspaceId,
              wri.credential_token_hash AS credentialTokenHash
       FROM workspace_runtime_identities wri
       JOIN execution_workspaces ew ON ew.id = wri.workspace_id
       WHERE wri.id = ?1
         AND wri.revoked_at IS NULL
         AND ew.status <> 'revoked'`,
    )
    .bind(workspaceRuntimeId)
    .first<{
      executionWorkspaceId: string;
      credentialTokenHash: string;
    }>();
  return row ?? null;
}
