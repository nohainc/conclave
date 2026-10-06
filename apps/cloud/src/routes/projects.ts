import { conditionalJson } from "./conditional-read.js";
import { publishCollaborationEvent } from "../collaboration-events.js";
import { hashToken, authorizeProjectOwner } from "@conclave/security";
import {
  HttpError,
  authorizeProjectOwnerOrThrow,
  authorizeRequest,
  json,
  parseJson,
  requiredString,
  securityContext,
  securityEnv,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";

function projectSettings(value: unknown): Record<string, unknown> {
  const settings = parseJson<Record<string, unknown>>(value);
  delete settings.defaultExecutionPolicy;
  return settings;
}

// =========================================================================
// Projects API Handlers
// =========================================================================

export async function handleListProjects(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    securityEnv(env),
    "projects:read",
    undefined,
    accessContext,
  );
  {
    const includeArchived =
      new URL(request.url).searchParams.get("archived") === "true";
    const rows = await env.CONCLAVE_DB.prepare(
      `SELECT p.id, p.name, p.description,
              p.settings_json AS settingsJson, p.created_at AS createdAt, p.updated_at AS updatedAt
       FROM projects p
       JOIN project_memberships pm ON pm.project_id = p.id
       WHERE pm.user_id = ?1
         ${includeArchived ? "" : "AND COALESCE(json_extract(p.settings_json, '$.archived'), 0) = 0"}
       ORDER BY p.updated_at DESC`,
    )
      .bind(context.userId)
      .all<{
        id: string;
        name: string;
        description: string | null;
        settingsJson: string;
        createdAt: string;
        updatedAt: string;
      }>();

    const projects = (rows.results ?? []).map((row) => {
      const settings = projectSettings(row.settingsJson);
      return {
        id: row.id,
        name: row.name,
        description: row.description,
        instructions:
          typeof settings.instructions === "string"
            ? settings.instructions
            : "",
        settings,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
      };
    });
    return json({ projects });
  }

  return json({ projects: [] });
}

export async function handleCreateProject(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "projects:manage",
    undefined,
    accessContext,
  );
  const body = (await request.json()) as Record<string, unknown>;
  const name = requiredString(body.name, "name");
  const description =
    typeof body.description === "string" ? body.description : null;
  const settings =
    typeof body.settings === "object" && body.settings !== null
      ? (body.settings as Record<string, unknown>)
      : {};
  delete settings.defaultExecutionPolicy;
  const now = new Date().toISOString();
  const id = `proj-${crypto.randomUUID()}`;

  {
    const duplicate = await env.CONCLAVE_DB.prepare(
      `SELECT id FROM projects
       WHERE owner_user_id = ?1 AND LOWER(TRIM(name)) = LOWER(TRIM(?2))
       LIMIT 1`,
    )
      .bind(context.userId, name)
      .first<{ id: string }>();
    if (duplicate) {
      throw new HttpError(409, "You already have a Project with this name");
    }
    // Projects are independent collaboration resources. Execution is attached
    // only through an explicit Workspace Project Grant.
    await publishCollaborationEvent(env, "project.created", id, id, {
      mutations: [
        env.CONCLAVE_DB.prepare(
          `INSERT INTO projects (id, owner_user_id, name, description, settings_json, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)`,
        ).bind(
          id,
          context.userId,
          name,
          description,
          JSON.stringify(settings),
          now,
        ),
        env.CONCLAVE_DB.prepare(
          `INSERT INTO project_memberships (id, project_id, user_id, role, created_at, updated_at)
         VALUES (?1, ?2, ?3, 'owner', ?4, ?4)
         ON CONFLICT(project_id, user_id) DO NOTHING`,
        ).bind(`pm-${crypto.randomUUID()}`, id, context.userId, now),
      ],
    });
    return json(
      {
        project: {
          id,
          name,
          description,
          instructions:
            typeof settings.instructions === "string"
              ? settings.instructions
              : "",
          settings,
          createdAt: now,
          updatedAt: now,
        },
      },
      { status: 201 },
    );
  }
}

export async function handleGetProject(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeRequest(
    request,
    env,
    "projects:read",
    projectId,
    accessContext,
  );
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT p.id, p.name, p.description,
            p.settings_json AS settingsJson, p.created_at AS createdAt, p.updated_at AS updatedAt
     FROM projects p WHERE p.id = ?1`,
  )
    .bind(projectId)
    .first<{
      id: string;
      name: string;
      description: string | null;
      settingsJson: string;
      createdAt: string;
      updatedAt: string;
    }>();
  if (!row) throw new HttpError(404, "Project not found");
  const settings = projectSettings(row.settingsJson);
  return conditionalJson(request, {
    project: {
      id: row.id,
      name: row.name,
      description: row.description,
      instructions:
        typeof settings.instructions === "string" ? settings.instructions : "",
      settings,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    },
  });
}

export async function handleUpdateProject(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeRequest(
    request,
    env,
    "projects:write",
    projectId,
    accessContext,
  );
  const existing = await env.CONCLAVE_DB.prepare(
    `SELECT id, owner_user_id AS ownerUserId, name, description,
            settings_json AS settingsJson,
            created_at AS createdAt, updated_at AS updatedAt
     FROM projects WHERE id = ?1`,
  )
    .bind(projectId)
    .first<{
      id: string;
      ownerUserId: string;
      name: string;
      description: string | null;
      settingsJson: string;
      createdAt: string;
      updatedAt: string;
    }>();
  if (!existing) throw new HttpError(404, "Project not found");

  const body = (await request.json()) as Record<string, unknown>;
  const settings = {
    ...projectSettings(existing.settingsJson),
    ...(typeof body.settings === "object" && body.settings !== null
      ? (body.settings as Record<string, unknown>)
      : {}),
  };
  delete settings.defaultExecutionPolicy;
  if (typeof body.instructions === "string") {
    settings.instructions = body.instructions;
  }
  if (body.archived === true) settings.archived = true;
  if (body.archived === false) settings.archived = false;
  const now = new Date().toISOString();
  const project = {
    id: existing.id,
    name:
      typeof body.name === "string" && body.name.trim().length > 0
        ? body.name.trim()
        : existing.name,
    description:
      body.description === null
        ? null
        : typeof body.description === "string"
          ? body.description
          : existing.description,
    settings,
    createdAt: existing.createdAt,
    updatedAt: now,
  };
  if (
    project.name.trim().toLowerCase() !== existing.name.trim().toLowerCase()
  ) {
    const duplicate = await env.CONCLAVE_DB.prepare(
      `SELECT id FROM projects
       WHERE owner_user_id = ?1 AND id <> ?2
         AND LOWER(TRIM(name)) = LOWER(TRIM(?3))
       LIMIT 1`,
    )
      .bind(existing.ownerUserId, projectId, project.name)
      .first<{ id: string }>();
    if (duplicate) {
      throw new HttpError(409, "You already have a Project with this name");
    }
  }
  const mutation = env.CONCLAVE_DB.prepare(
    `UPDATE projects SET name = ?1, description = ?2,
       settings_json = ?3, updated_at = ?4
     WHERE id = ?5`,
  ).bind(
    project.name,
    project.description,
    JSON.stringify(project.settings),
    now,
    projectId,
  );
  await publishCollaborationEvent(
    env,
    settings.archived === true &&
      projectSettings(existing.settingsJson).archived !== true
      ? "project.archived"
      : "project.updated",
    projectId,
    projectId,
    { mutations: [mutation] },
  );
  return json({
    project: {
      ...project,
      instructions:
        typeof project.settings.instructions === "string"
          ? project.settings.instructions
          : "",
    },
  });
}

export async function handleDeleteProject(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "projects:manage",
    projectId,
    accessContext,
  );
  {
    try {
      await authorizeProjectOwner(
        env.CONCLAVE_DB,
        context,
        projectId,
        "projects:manage",
      );
    } catch (error) {
      throw new HttpError(
        403,
        error instanceof Error ? error.message : "Forbidden",
      );
    }
    const audience = await env.CONCLAVE_DB.prepare(
      "SELECT user_id FROM project_memberships WHERE project_id = ?1",
    )
      .bind(projectId)
      .all<{ user_id: string }>();
    const workstreamFilter = "SELECT id FROM workstreams WHERE project_id = ?1";
    const workRequestFilter = `SELECT id FROM work_requests WHERE workstream_id IN (${workstreamFilter})`;
    const workflowTaskFilter = `SELECT id FROM workflow_tasks WHERE work_request_id IN (${workRequestFilter})`;
    // Ordered transactional cleanup removes children before their parents and
    // commits the deletion signal with the mutation.
    const cleanupStatements = [
      `DELETE FROM workflow_task_dependencies
       WHERE task_id IN (${workflowTaskFilter})
          OR depends_on_task_id IN (${workflowTaskFilter})`,
      `DELETE FROM workflow_tasks
       WHERE work_request_id IN (${workRequestFilter})`,
      "DELETE FROM worker_assignments WHERE project_id = ?1",
      "DELETE FROM runs WHERE project_id = ?1",
      `DELETE FROM work_requests
       WHERE workstream_id IN (${workstreamFilter})`,
      `DELETE FROM workstream_execution_policies
       WHERE workstream_id IN (${workstreamFilter})`,
      `DELETE FROM discussion_messages
       WHERE workstream_id IN (${workstreamFilter})`,
      "DELETE FROM workstreams WHERE project_id = ?1",
      "DELETE FROM workspace_project_grants WHERE project_id = ?1",
      "DELETE FROM project_invitations WHERE project_id = ?1",
      "DELETE FROM project_audit_log WHERE project_id = ?1",
      "DELETE FROM project_memberships WHERE project_id = ?1",
      "DELETE FROM artifacts WHERE project_id = ?1",
      "DELETE FROM projects WHERE id = ?1",
    ];
    await publishCollaborationEvent(
      env,
      "project.deleted",
      projectId,
      projectId,
      {
        recipientUserIds: (audience.results ?? []).map((row) => row.user_id),
        mutations: cleanupStatements.map((sql) =>
          env.CONCLAVE_DB.prepare(sql).bind(projectId),
        ),
      },
    );
    return json({ projectId, deleted: true });
  }
}

export async function handleListProjectMembers(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeRequest(
    request,
    env,
    "projects:read",
    projectId,
    accessContext,
  );
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT pm.user_id AS userId, u.display_name AS displayName, u.email, pm.role, pm.created_at AS createdAt
     FROM project_memberships pm JOIN users u ON u.id = pm.user_id
     WHERE pm.project_id = ?1 ORDER BY CASE pm.role WHEN 'owner' THEN 0 WHEN 'collaborator' THEN 1 ELSE 2 END, u.display_name`,
  )
    .bind(projectId)
    .all();
  return json({ members: rows.results ?? [] });
}

export async function handleListProjectInvitations(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeProjectOwnerOrThrow(request, env, projectId, accessContext);
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT id, email, role, status, expires_at AS expiresAt, created_at AS createdAt
     FROM project_invitations WHERE project_id = ?1 AND status = 'pending' ORDER BY created_at DESC`,
  )
    .bind(projectId)
    .all();
  return json({ invitations: rows.results ?? [] });
}

export async function handleListProjectAudit(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeRequest(
    request,
    env,
    "projects:read",
    projectId,
    accessContext,
  );
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT id, action, target_type AS targetType, target_id AS targetId, created_at AS createdAt
     FROM project_audit_log WHERE project_id = ?1 ORDER BY created_at DESC LIMIT 100`,
  )
    .bind(projectId)
    .all();
  return json({ entries: rows.results ?? [] });
}

export async function handleCreateProjectInvitation(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeProjectOwnerOrThrow(
    request,
    env,
    projectId,
    accessContext,
  );
  const body = (await request.json()) as Record<string, unknown>;
  const email = requiredString(body.email, "email").trim().toLowerCase();
  const role =
    body.role === "viewer" || body.role === "collaborator" ? body.role : null;
  if (!role || !email.includes("@"))
    throw new HttpError(400, "Valid email and Project role are required");
  const existingMember = await env.CONCLAVE_DB.prepare(
    `SELECT pm.user_id FROM project_memberships pm
     JOIN users u ON u.id = pm.user_id
     WHERE pm.project_id = ?1 AND LOWER(u.email) = LOWER(?2)
     LIMIT 1`,
  )
    .bind(projectId, email)
    .first<{ user_id: string }>();
  if (existingMember) {
    throw new HttpError(409, "This user is already a Project member");
  }
  const existingInvitation = await env.CONCLAVE_DB.prepare(
    `SELECT id FROM project_invitations
     WHERE project_id = ?1 AND status = 'pending' AND LOWER(email) = LOWER(?2)
     LIMIT 1`,
  )
    .bind(projectId, email)
    .first<{ id: string }>();
  if (existingInvitation) {
    throw new HttpError(
      409,
      "A pending invitation already exists for this user",
    );
  }
  const now = new Date();
  const id = `pinv-${crypto.randomUUID()}`;
  const token = `project_invite_${crypto.randomUUID()}_${crypto.randomUUID()}`;
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO project_invitations (id, project_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'pending', ?7, ?8, ?8)`,
  )
    .bind(
      id,
      projectId,
      email,
      role,
      await hashToken(token),
      context.userId,
      new Date(now.getTime() + 7 * 86400000).toISOString(),
      now.toISOString(),
    )
    .run();
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO project_audit_log (id, project_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
     VALUES (?1, ?2, 'user', ?3, 'project.invitation.created', 'invitation', ?4, ?5, ?6)`,
  )
    .bind(
      `pa-${crypto.randomUUID()}`,
      projectId,
      context.userId,
      id,
      JSON.stringify({ email, role }),
      now.toISOString(),
    )
    .run();
  return json(
    { invitation: { id, projectId, email, role, status: "pending" }, token },
    { status: 201 },
  );
}

export async function handleChangeProjectMemberRole(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  userId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeProjectOwnerOrThrow(
    request,
    env,
    projectId,
    accessContext,
  );
  const body = (await request.json()) as Record<string, unknown>;
  const role =
    body.role === "viewer" || body.role === "collaborator" ? body.role : null;
  if (!role)
    throw new HttpError(400, "Project role must be collaborator or viewer");
  const result = await env.CONCLAVE_DB.prepare(
    `UPDATE project_memberships SET role = ?1, updated_at = ?2 WHERE project_id = ?3 AND user_id = ?4 AND role <> 'owner'`,
  )
    .bind(role, new Date().toISOString(), projectId, userId)
    .run();
  if (!result.success || (result.meta?.changes ?? 0) === 0)
    throw new HttpError(404, "Project member not found");
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO project_audit_log (id, project_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at) VALUES (?1, ?2, 'user', ?3, 'project.member.role_changed', 'user', ?4, ?5, ?6)`,
  )
    .bind(
      `pa-${crypto.randomUUID()}`,
      projectId,
      context.userId,
      userId,
      JSON.stringify({ role }),
      new Date().toISOString(),
    )
    .run();
  return json({ projectId, userId, role });
}

export async function handleRemoveProjectMember(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  userId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeProjectOwnerOrThrow(
    request,
    env,
    projectId,
    accessContext,
  );
  const result = await env.CONCLAVE_DB.prepare(
    `DELETE FROM project_memberships WHERE project_id = ?1 AND user_id = ?2 AND role <> 'owner'`,
  )
    .bind(projectId, userId)
    .run();
  if (!result.success || (result.meta?.changes ?? 0) === 0)
    throw new HttpError(404, "Project member not found");
  // A contributed execution Workspace is owned by the departing user. Revoke
  // that user's Project Grants with the membership removal so the scheduler
  // cannot continue using infrastructure after collaboration ends.
  await env.CONCLAVE_DB.prepare(
    `UPDATE workspace_project_grants
        SET status = 'revoked', updated_at = ?1
      WHERE project_id = ?2 AND granted_by_user_id = ?3
        AND status IN ('active', 'suspended')`,
  )
    .bind(new Date().toISOString(), projectId, userId)
    .run();
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO project_audit_log (id, project_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at) VALUES (?1, ?2, 'user', ?3, 'project.member.removed', 'user', ?4, '{}', ?5)`,
  )
    .bind(
      `pa-${crypto.randomUUID()}`,
      projectId,
      context.userId,
      userId,
      new Date().toISOString(),
    )
    .run();
  return json({ projectId, userId, removed: true });
}

export async function handleExpireProjectInvitation(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  invitationId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeProjectOwnerOrThrow(
    request,
    env,
    projectId,
    accessContext,
  );
  const result = await env.CONCLAVE_DB.prepare(
    `UPDATE project_invitations SET status = 'expired', updated_at = ?1 WHERE id = ?2 AND project_id = ?3 AND status = 'pending'`,
  )
    .bind(new Date().toISOString(), invitationId, projectId)
    .run();
  if (!result.success || (result.meta?.changes ?? 0) === 0)
    throw new HttpError(404, "Pending invitation not found");
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO project_audit_log (id, project_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at) VALUES (?1, ?2, 'user', ?3, 'project.invitation.expired', 'invitation', ?4, '{}', ?5)`,
  )
    .bind(
      `pa-${crypto.randomUUID()}`,
      projectId,
      context.userId,
      invitationId,
      new Date().toISOString(),
    )
    .run();
  return json({ id: invitationId, status: "expired" });
}

export async function handleAcceptProjectInvitation(
  request: Request,
  env: SecurityEnv,
  invitationId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const invitation = await env.CONCLAVE_DB.prepare(
    `SELECT id, project_id AS projectId, email, role, status, expires_at AS expiresAt
     FROM project_invitations WHERE id = ?1`,
  )
    .bind(invitationId)
    .first<{
      id: string;
      projectId: string;
      email: string;
      role: "collaborator" | "viewer";
      status: string;
      expiresAt: string;
    }>();
  if (!invitation || invitation.status !== "pending")
    throw new HttpError(404, "Project invitation not found");
  if (new Date(invitation.expiresAt).getTime() <= Date.now())
    throw new HttpError(410, "Project invitation expired");
  if (context.user.email.toLowerCase() !== invitation.email.toLowerCase())
    throw new HttpError(403, "Invitation email does not match signed-in user");
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      `INSERT INTO project_memberships (id, project_id, user_id, role, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?5) ON CONFLICT(project_id, user_id) DO UPDATE SET role = excluded.role, updated_at = excluded.updated_at`,
    ).bind(
      `pm-${crypto.randomUUID()}`,
      invitation.projectId,
      context.userId,
      invitation.role,
      now,
    ),
    env.CONCLAVE_DB.prepare(
      `UPDATE project_invitations SET status = 'accepted', accepted_by_user_id = ?1, accepted_at = ?2, updated_at = ?2 WHERE id = ?3 AND status = 'pending'`,
    ).bind(context.userId, now, invitation.id),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO project_audit_log (id, project_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at) VALUES (?1, ?2, 'user', ?3, 'project.invitation.accepted', 'invitation', ?4, '{}', ?5)`,
    ).bind(
      `pa-${crypto.randomUUID()}`,
      invitation.projectId,
      context.userId,
      invitation.id,
      now,
    ),
  ]);
  return json({
    projectId: invitation.projectId,
    role: invitation.role,
    accepted: true,
  });
}
