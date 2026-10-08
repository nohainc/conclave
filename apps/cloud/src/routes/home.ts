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

  // 1. Authorized Projects for this user
  const projectsRows = await env.CONCLAVE_DB.prepare(
    `SELECT p.id, p.name, p.description, pm.role,
            p.settings_json AS settingsJson, p.created_at AS createdAt, p.updated_at AS updatedAt
     FROM projects p
     JOIN project_memberships pm ON pm.project_id = p.id
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

  const authorizedProjects = projectsRows.results ?? [];
  const authorizedProjectIds = authorizedProjects.map((p) => p.id);

  // 2. Pending Invitations for this user
  const invitationsRows = await env.CONCLAVE_DB.prepare(
    `SELECT 
       pi.id,
       pi.project_id AS projectId,
       p.name AS projectName,
       pi.email,
       pi.role,
       pi.status,
       pi.invited_by_user_id AS invitedByUserId,
       u.display_name AS invitedByUserName,
       u.email AS invitedByUserEmail,
       pi.expires_at AS expiresAt,
       pi.created_at AS createdAt
     FROM project_invitations pi
     JOIN projects p ON p.id = pi.project_id
     JOIN users u ON u.id = pi.invited_by_user_id
     WHERE LOWER(pi.email) = ?1 AND pi.status = 'pending' AND pi.expires_at > ?2
     ORDER BY pi.created_at DESC`,
  )
    .bind(email, now)
    .all<{
      id: string;
      projectId: string;
      projectName: string;
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
      type: "project_invitation",
      kind: "project_invitation",
      priority: 1,
      title: `${inv.invitedByUserName || inv.invitedByUserEmail || "A collaborator"} invited you to ${inv.projectName}`,
      subtitle: `${inv.role.toUpperCase()}`,
      description: `${inv.role.toUpperCase()}`,
      projectId: inv.projectId,
      invitation: inv,
      unread: true,
      actionable: true,
      createdAt: inv.createdAt,
    });
  }

  if (authorizedProjectIds.length > 0) {
    const placeholders = authorizedProjectIds
      .map((_, i) => `?${i + 1}`)
      .join(", ");
    const attentionWorkRows = await env.CONCLAVE_DB.prepare(
      `SELECT wr.id, wr.project_id AS projectId, p.name AS projectName,
              wr.workstream_id AS workstreamId, ws.name AS workstreamTitle,
              wr.status, wr.workflow_id AS workflowId, wr.input_json AS inputJson,
              wr.created_at AS createdAt, wr.updated_at AS updatedAt
       FROM work_requests wr
       JOIN projects p ON p.id = wr.project_id
       JOIN workstreams ws ON ws.id = wr.workstream_id
       WHERE wr.project_id IN (${placeholders})
         AND wr.status IN ('failed', 'awaiting_input', 'needs_approval')
       ORDER BY wr.updated_at DESC
       LIMIT 10`,
    )
      .bind(...authorizedProjectIds)
      .all<{
        id: string;
        projectId: string;
        projectName: string;
        workstreamId: string;
        workstreamTitle: string;
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
          ? `Execution failed on ${w.workstreamTitle}`
          : `${w.workstreamTitle} needs your input`,
        subtitle: w.projectName,
        description: isFailed
          ? "Review failure and diagnostic logs"
          : "Action required to proceed",
        projectId: w.projectId,
        workstreamId: w.workstreamId,
        unread: true,
        actionable: true,
        createdAt: w.updatedAt || w.createdAt,
      });
    }
  }

  // 4. Running Now (active execution runs in member projects)
  const running: Array<Record<string, unknown>> = [];
  if (authorizedProjectIds.length > 0) {
    const placeholders = authorizedProjectIds
      .map((_, i) => `?${i + 1}`)
      .join(", ");
    const runningRows = await env.CONCLAVE_DB.prepare(
      `SELECT wr.id, wr.project_id AS projectId, p.name AS projectName,
              wr.workstream_id AS workstreamId, ws.name AS workstreamTitle,
              wr.status, wr.workflow_id AS workflowId, wr.input_json AS inputJson,
              wr.snapshot_json AS snapshotJson,
              (SELECT text FROM conversation_history_entries h WHERE h.work_request_id = wr.id AND h.kind = 'user_message' LIMIT 1) AS canonicalUserText,
              wr.created_at AS createdAt, wr.updated_at AS updatedAt
       FROM work_requests wr
       JOIN projects p ON p.id = wr.project_id
       JOIN workstreams ws ON ws.id = wr.workstream_id
       WHERE wr.project_id IN (${placeholders})
         AND wr.status IN ('running', 'in_progress', 'queued')
       ORDER BY wr.created_at DESC
       LIMIT 5`,
    )
      .bind(...authorizedProjectIds)
      .all<{
        id: string;
        projectId: string;
        projectName: string;
        workstreamId: string;
        workstreamTitle: string;
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
        projectId: r.projectId,
        projectName: r.projectName,
        workstreamId: r.workstreamId,
        workstreamTitle: r.workstreamTitle,
        status: r.status,
        objective,
        startedAt: r.createdAt,
        taskCount: 1,
        completedTaskCount: 0,
      });
    }
  }

  // 5. Recent Work (active non-archived workstreams for member projects)
  const recentWork: Array<Record<string, unknown>> = [];
  if (authorizedProjectIds.length > 0) {
    const placeholders = authorizedProjectIds
      .map((_, i) => `?${i + 1}`)
      .join(", ");
    const workstreamRows = await env.CONCLAVE_DB.prepare(
      `SELECT ws.id AS workstreamId, ws.name AS workstreamTitle, ws.project_id AS projectId,
              p.name AS projectName, ws.lead_user_id AS leadUserId, ws.created_at AS createdAt,
              ws.updated_at AS updatedAt,
              COALESCE((SELECT m.content FROM discussion_messages m WHERE m.workstream_id = ws.id ORDER BY m.created_at DESC LIMIT 1),
                       (SELECT h.text FROM conversation_history_entries h JOIN conversation_work_requests cwr ON cwr.conversation_id = h.conversation_id WHERE cwr.workstream_id = ws.id ORDER BY h.created_at DESC LIMIT 1),
                       'Continue conversation and work in context') AS lastMessageSnippet
       FROM workstreams ws
       JOIN projects p ON p.id = ws.project_id
       WHERE ws.project_id IN (${placeholders})
         AND COALESCE(json_extract(ws.access_policy_json, '$.archived'), 0) = 0
       ORDER BY ws.updated_at DESC
       LIMIT 10`,
    )
      .bind(...authorizedProjectIds)
      .all<{
        workstreamId: string;
        workstreamTitle: string;
        projectId: string;
        projectName: string;
        leadUserId: string | null;
        createdAt: string;
        updatedAt: string;
        lastMessageSnippet: string;
      }>();

    for (const ws of workstreamRows.results ?? []) {
      recentWork.push({
        projectId: ws.projectId,
        projectName: ws.projectName,
        workstreamId: ws.workstreamId,
        workstreamTitle: ws.workstreamTitle,
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
      summary: "Connect local environments securely to your Conclave Projects.",
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
