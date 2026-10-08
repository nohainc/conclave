import { createHash } from "node:crypto";
import type { Conversation, WorkflowDefinition } from "@conclave/core";
import { authorizeThreadAccess, json, type SecurityEnv } from "./handlers.js";

/** Phase 1 has one implicit Conversation per Thread/manual workflow. */
export function conversationId(threadId: string, workflowId: string): string {
  return `conversation-${createHash("sha256")
    .update(JSON.stringify([threadId, workflowId]))
    .digest("hex")}`;
}

export function conversationSubmissionStatements(
  db: D1Database,
  threadId: string,
  definition: WorkflowDefinition,
  workRequestId: string,
  now: string,
): D1PreparedStatement[] {
  const id = conversationId(threadId, definition.id);
  return [
    db
      .prepare(
        `INSERT INTO conversations
      (id, thread_id, workflow_id, workflow_version, conversation_revision, context_revision, created_at, updated_at)
      VALUES (?1, ?2, ?3, ?4, 1, 1, ?5, ?5)
      ON CONFLICT (thread_id, workflow_id) DO UPDATE SET
        conversation_revision = conversation_revision + 1, context_revision = conversation_revision + 1, updated_at = excluded.updated_at`,
      )
      .bind(id, threadId, definition.id, definition.version, now),
    db
      .prepare(
        `INSERT INTO conversation_work_requests
      (conversation_id, work_request_id, conversation_revision)
      SELECT id, ?2, conversation_revision FROM conversations WHERE id = ?1`,
      )
      .bind(id, workRequestId),
  ];
}

export async function handleListConversations(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeThreadAccess(request, env, threadId, "view", accessContext);
  const result = await env.CONCLAVE_DB.prepare(
    `SELECT id, thread_id AS threadId,
    workflow_id AS workflowId, workflow_version AS workflowVersion,
    conversation_revision AS conversationRevision, context_revision AS contextRevision,
    created_at AS createdAt, updated_at AS updatedAt
    FROM conversations WHERE thread_id = ?1 ORDER BY created_at, id`,
  )
    .bind(threadId)
    .all<Conversation>();
  return json({ conversations: result.results ?? [] });
}
