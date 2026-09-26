export async function recordExecutionWorkspaceAudit(
  db: D1Database,
  input: {
    readonly workspaceId: string;
    readonly ownerUserId: string;
    readonly actorType: "user" | "workspace_runtime" | "worker" | "system";
    readonly actorId: string;
    readonly action: string;
    readonly targetType: string;
    readonly targetId: string;
    readonly details?: Record<string, unknown>;
  },
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO execution_workspace_audit_log
       (id, execution_workspace_id, workspace_owner_user_id, actor_type, actor_id,
        action, target_type, target_id, details_json, created_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)`,
    )
    .bind(
      `ewa-${crypto.randomUUID()}`,
      input.workspaceId,
      input.ownerUserId,
      input.actorType,
      input.actorId,
      input.action,
      input.targetType,
      input.targetId,
      JSON.stringify(input.details ?? {}),
      new Date().toISOString(),
    )
    .run();
}
