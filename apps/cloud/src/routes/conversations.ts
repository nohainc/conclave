import { createHash } from "node:crypto";
import type { Conversation, WorkflowDefinition } from "@conclave/core";
import {
  authorizeWorkstreamAccess,
  json,
  type SecurityEnv,
} from "./handlers.js";

/** Phase 1 has one implicit Conversation per Workstream/manual workflow. */
export function conversationId(
  workstreamId: string,
  workflowId: string,
): string {
  return `conversation-${createHash("sha256")
    .update(JSON.stringify([workstreamId, workflowId]))
    .digest("hex")}`;
}

export function conversationSubmissionStatements(
  db: D1Database,
  workstreamId: string,
  definition: WorkflowDefinition,
  workRequestId: string,
  now: string,
): D1PreparedStatement[] {
  const id = conversationId(workstreamId, definition.id);
  return [
    db
      .prepare(
        `INSERT INTO conversations
      (id, workstream_id, workflow_id, workflow_version, conversation_revision, context_revision, created_at, updated_at)
      VALUES (?1, ?2, ?3, ?4, 1, 1, ?5, ?5)
      ON CONFLICT (workstream_id, workflow_id) DO UPDATE SET
        conversation_revision = conversation_revision + 1, context_revision = conversation_revision + 1, updated_at = excluded.updated_at`,
      )
      .bind(id, workstreamId, definition.id, definition.version, now),
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
  workstreamId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeWorkstreamAccess(
    request,
    env,
    workstreamId,
    "view",
    accessContext,
  );
  const result = await env.CONCLAVE_DB.prepare(
    `SELECT id, workstream_id AS workstreamId,
    workflow_id AS workflowId, workflow_version AS workflowVersion,
    conversation_revision AS conversationRevision, context_revision AS contextRevision,
    created_at AS createdAt, updated_at AS updatedAt
    FROM conversations WHERE workstream_id = ?1 ORDER BY created_at, id`,
  )
    .bind(workstreamId)
    .all<Conversation>();
  return json({ conversations: result.results ?? [] });
}
