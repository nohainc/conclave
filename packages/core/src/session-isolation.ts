export const SESSION_MODES = ["fresh", "task", "chat", "project"] as const;
export type SessionMode = (typeof SESSION_MODES)[number];

export interface WorkerSessionNamespace {
  readonly workerId: string;
  readonly credentialProfileId: string;
  readonly projectId?: string | null;
  readonly sessionId: string;
  readonly mode: SessionMode;
}

export function createWorkerSessionNamespace(
  input: Omit<WorkerSessionNamespace, "sessionId"> & { sessionId: string },
): string {
  for (const [field, value] of Object.entries(input)) {
    if (field === "projectId") continue;
    if (typeof value !== "string" || value.trim().length === 0) {
      throw new Error(`${field} is required for a Worker session namespace`);
    }
  }
  if (input.mode !== "fresh" && !input.projectId) {
    throw new Error(`projectId is required for ${input.mode} Worker sessions`);
  }
  return [
    input.workerId,
    input.credentialProfileId,
    input.projectId ?? "_workspace",
    input.mode,
    input.sessionId,
  ]
    .map((part) => encodeURIComponent(part))
    .join("/");
}

/**
 * Provider history may only be reused within the same Worker/profile scope.
 * Fresh sessions deliberately never reuse provider state, even when all other
 * inputs happen to match.
 */
export function canReuseWorkerSession(
  existing: WorkerSessionNamespace,
  requested: WorkerSessionNamespace,
): boolean {
  if (
    existing.workerId !== requested.workerId ||
    existing.credentialProfileId !== requested.credentialProfileId ||
    existing.projectId !== requested.projectId
  ) {
    return false;
  }
  if (requested.mode === "fresh" || existing.mode === "fresh") return false;
  return existing.sessionId === requested.sessionId;
}
