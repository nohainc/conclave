import { json, parseJson, securityContext, securityEnv } from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";

export async function handleGetHomeReadModel(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(
    request,
    securityEnv(env),
    accessContext,
  );
  const now = new Date().toISOString();
  const email = context.user.email.trim().toLowerCase();

  // 1. Authorized Spaces for this user
  const spacesRows = await env.CONCLAVE_DB.prepare(
    `SELECT p.id, p.name, p.description, pm.role,
            p.settings_json AS settingsJson, p.created_at AS createdAt, p.updated_at AS updatedAt
     FROM spaces p
     JOIN space_memberships pm ON pm.space_id = p.id
     WHERE pm.user_id = ?1
       AND COALESCE(json_extract(p.settings_json, '$.archived'), 0) = 0
     ORDER BY p.updated_at DESC`,
  )
    .bind(context.userId)
    .all<{
      id: string;
      name: string;
      description: string | null;
      role: string;
      settingsJson: string;
      createdAt: string;
      updatedAt: string;
    }>();

  const authorizedSpaces = spacesRows.results ?? [];
  const authorizedSpaceIds = authorizedSpaces.map((p) => p.id);

  // 2. Pending Invitations for this user
  const invitationsRows = await env.CONCLAVE_DB.prepare(
    `SELECT 
       pi.id,
       pi.space_id AS spaceId,
       p.name AS spaceName,
       pi.email,
       pi.role,
       pi.status,
       pi.invited_by_user_id AS invitedByUserId,
       u.display_name AS invitedByUserName,
       u.email AS invitedByUserEmail,
       pi.expires_at AS expiresAt,
       pi.created_at AS createdAt
     FROM space_invitations pi
     JOIN spaces p ON p.id = pi.space_id
     JOIN users u ON u.id = pi.invited_by_user_id
     WHERE LOWER(pi.email) = ?1 AND pi.status = 'pending' AND pi.expires_at > ?2
     ORDER BY pi.created_at DESC`,
  )
    .bind(email, now)
    .all<{
      id: string;
      spaceId: string;
      spaceName: string;
      email: string;
      role: string;
      status: string;
      invitedByUserId: string;
      invitedByUserName: string;
      invitedByUserEmail: string;
      expiresAt: string;
      createdAt: string;
    }>();

  const invitations = invitationsRows.results ?? [];

  // 3. Attention Items (projection over pending invitations and work requests needing attention)
  const attention: Array<Record<string, unknown>> = [];

  for (const inv of invitations) {
    attention.push({
      id: `invite-${inv.id}`,
      type: "space_invitation",
      kind: "space_invitation",
      priority: 1,
      title: `${inv.invitedByUserName || inv.invitedByUserEmail || "A collaborator"} invited you to ${inv.spaceName}`,
      subtitle: `${inv.role.toUpperCase()}`,
      description: `${inv.role.toUpperCase()}`,
      spaceId: inv.spaceId,
      invitation: inv,
      unread: true,
      actionable: true,
      createdAt: inv.createdAt,
    });
  }

  if (authorizedSpaceIds.length > 0) {
    const placeholders = authorizedSpaceIds
      .map((_, i) => `?${i + 1}`)
      .join(", ");
    const attentionWorkRows = await env.CONCLAVE_DB.prepare(
      `SELECT wr.id, wr.space_id AS spaceId, p.name AS spaceName,
              wr.thread_id AS threadId, ws.name AS threadTitle,
              wr.status, wr.workflow_id AS workflowId, wr.input_json AS inputJson,
              wr.created_at AS createdAt, wr.updated_at AS updatedAt
       FROM work_requests wr
       JOIN spaces p ON p.id = wr.space_id
       JOIN threads ws ON ws.id = wr.thread_id
       WHERE wr.space_id IN (${placeholders})
         AND wr.status IN ('failed', 'awaiting_input', 'needs_approval')
       ORDER BY wr.updated_at DESC
       LIMIT 10`,
    )
      .bind(...authorizedSpaceIds)
      .all<{
        id: string;
        spaceId: string;
        spaceName: string;
        threadId: string;
        threadTitle: string;
        status: string;
        workflowId: string;
        inputJson: string;
        createdAt: string;
        updatedAt: string;
      }>();

    for (const w of attentionWorkRows.results ?? []) {
      const isFailed = w.status === "failed";
      attention.push({
        id: `work-${w.id}`,
        type: isFailed ? "execution_failed" : "needs_input",
        kind: isFailed ? "execution_failed" : "needs_input",
        priority: isFailed ? 3 : 2,
        title: isFailed
          ? `Execution failed on ${w.threadTitle}`
          : `${w.threadTitle} needs your input`,
        subtitle: w.spaceName,
        description: isFailed
          ? "Review failure and diagnostic logs"
          : "Action required to proceed",
        spaceId: w.spaceId,
        threadId: w.threadId,
        unread: true,
        actionable: true,
        createdAt: w.updatedAt || w.createdAt,
      });
    }
  }

  // 4. Running Now (active execution runs in member spaces)
  const running: Array<Record<string, unknown>> = [];
  if (authorizedSpaceIds.length > 0) {
    const placeholders = authorizedSpaceIds
      .map((_, i) => `?${i + 1}`)
      .join(", ");
    const runningRows = await env.CONCLAVE_DB.prepare(
      `SELECT wr.id, wr.space_id AS spaceId, p.name AS spaceName,
              wr.thread_id AS threadId, ws.name AS threadTitle,
              wr.status, wr.workflow_id AS workflowId, wr.input_json AS inputJson,
              wr.snapshot_json AS snapshotJson,
              (SELECT text FROM conversation_history_entries h WHERE h.work_request_id = wr.id AND h.kind = 'user_message' LIMIT 1) AS canonicalUserText,
              wr.created_at AS createdAt, wr.updated_at AS updatedAt
       FROM work_requests wr
       JOIN spaces p ON p.id = wr.space_id
       JOIN threads ws ON ws.id = wr.thread_id
       WHERE wr.space_id IN (${placeholders})
         AND wr.status IN ('running', 'in_progress', 'queued')
       ORDER BY wr.created_at DESC
       LIMIT 5`,
    )
      .bind(...authorizedSpaceIds)
      .all<{
        id: string;
        spaceId: string;
        spaceName: string;
        threadId: string;
        threadTitle: string;
        status: string;
        workflowId: string;
        inputJson: string;
        snapshotJson: string | null;
        canonicalUserText: string | null;
        createdAt: string;
        updatedAt: string;
      }>();

    for (const r of runningRows.results ?? []) {
      const input = parseJson<Record<string, unknown>>(r.inputJson, {});
      const objective =
        r.canonicalUserText ||
        String(
          input.originalRequest ??
            input.request ??
            input.objective ??
            "Active Execution",
        );
      running.push({
        id: r.id,
        spaceId: r.spaceId,
        spaceName: r.spaceName,
        threadId: r.threadId,
        threadTitle: r.threadTitle,
        status: r.status,
        objective,
        startedAt: r.createdAt,
        taskCount: 1,
        completedTaskCount: 0,
      });
    }
  }

  // 5. Recent Work (active non-archived threads for member spaces)
  const recentWork: Array<Record<string, unknown>> = [];
  if (authorizedSpaceIds.length > 0) {
    const placeholders = authorizedSpaceIds
      .map((_, i) => `?${i + 1}`)
      .join(", ");
    const threadRows = await env.CONCLAVE_DB.prepare(
      `SELECT ws.id AS threadId, ws.name AS threadTitle, ws.space_id AS spaceId,
              p.name AS spaceName, ws.lead_user_id AS leadUserId, ws.created_at AS createdAt,
              ws.updated_at AS updatedAt,
              COALESCE((SELECT m.content FROM discussion_messages m WHERE m.thread_id = ws.id ORDER BY m.created_at DESC LIMIT 1),
                       (SELECT h.text FROM conversation_history_entries h JOIN conversation_work_requests cwr ON cwr.conversation_id = h.conversation_id WHERE cwr.thread_id = ws.id ORDER BY h.created_at DESC LIMIT 1),
                       'Continue conversation and work in context') AS lastMessageSnippet
       FROM threads ws
       JOIN spaces p ON p.id = ws.space_id
       WHERE ws.space_id IN (${placeholders})
         AND COALESCE(json_extract(ws.access_policy_json, '$.archived'), 0) = 0
       ORDER BY ws.updated_at DESC
       LIMIT 10`,
    )
      .bind(...authorizedSpaceIds)
      .all<{
        threadId: string;
        threadTitle: string;
        spaceId: string;
        spaceName: string;
        leadUserId: string | null;
        createdAt: string;
        updatedAt: string;
        lastMessageSnippet: string;
      }>();

    for (const ws of threadRows.results ?? []) {
      recentWork.push({
        spaceId: ws.spaceId,
        spaceName: ws.spaceName,
        threadId: ws.threadId,
        threadTitle: ws.threadTitle,
        collaboratorsDisplay: ws.leadUserId
          ? `Lead: ${ws.leadUserId}`
          : "You and team AI",
        lastMessageSnippet: ws.lastMessageSnippet,
        lastActivityDisplay: ws.updatedAt || ws.createdAt,
        updatedAt: ws.updatedAt || ws.createdAt,
      });
    }
  }

  // 6. Product Updates (published release announcements)
  const productUpdates = [
    {
      id: "up-conclave-v8",
      slug: "conclave-v8-architecture",
      title: "Conclave v8 Architecture",
      summary:
        "Provider-independent CLI Worker Engine with signed Tool Profiles.",
      category: "workflow",
      publishedAt: "2026-10-07T00:00:00Z",
      status: "published",
    },
    {
      id: "up-desktop-workspace",
      slug: "workspace-pairing",
      title: "Seamless Workspace Pairing",
      summary: "Connect local environments securely to your Conclave Spaces.",
      category: "collaboration",
      publishedAt: "2026-10-06T00:00:00Z",
      status: "published",
    },
  ];

  // 7. AI Updates (catalog/model updates)
  const aiUpdates = [
    {
      id: "ai-chatgpt-models",
      workerProfileId: "chatgpt",
      provider: "openai",
      type: "model_added",
      modelId: "gpt-4o",
      modelDisplayName: "GPT-4o & Reasoning",
      title: "Supported model catalog updated",
      summary:
        "Auto model and latest reasoning models are selectable for your requests.",
      publishedAt: "2026-10-07T00:00:00Z",
      dateDisplay: "Oct 7",
    },
    {
      id: "ai-gemini-models",
      workerProfileId: "gemini",
      provider: "google",
      type: "capability_added",
      title: "Multi-modal search & tools",
      summary:
        "Gemini Worker supports grounded web search and structured outputs.",
      publishedAt: "2026-10-05T00:00:00Z",
      dateDisplay: "Oct 5",
    },
    {
      id: "ai-claude-artifacts",
      workerProfileId: "claude",
      provider: "anthropic",
      type: "capability_changed",
      title: "Interactive artifact synthesis",
      summary:
        "Claude Worker streams interactive artifacts and code snippets directly.",
      publishedAt: "2026-10-02T00:00:00Z",
      dateDisplay: "Oct 2",
    },
  ];

  return json({
    attention,
    running,
    recentWork,
    productUpdates,
    aiUpdates,
  });
}
