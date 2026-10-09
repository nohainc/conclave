import { loadSpaceWorkflowConfigurations } from "./space-workflow-configurations.js";
import {
  SPACE_MEMBER_PERMISSION_KEYS,
  spaceMemberPermissions,
  type SpaceMemberPermissions,
  type SecurityContext,
} from "@conclave/security";
import { HttpError } from "./http-security.js";
import type { SecurityEnv } from "./http-security.js";

export function validateMemberPermissions(
  value: unknown,
): SpaceMemberPermissions {
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    Object.keys(value).length !== SPACE_MEMBER_PERMISSION_KEYS.length ||
    SPACE_MEMBER_PERMISSION_KEYS.some(
      (key) => typeof (value as Record<string, unknown>)[key] !== "boolean",
    )
  ) {
    throw new HttpError(
      400,
      "All five member permissions must be boolean values",
    );
  }
  return value as SpaceMemberPermissions;
}

export async function loadSpacePermissions(
  env: Pick<SecurityEnv, "CONCLAVE_DB">,
  userId: string,
  spaceId: string,
) {
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT sm.role, s.settings_json AS settingsJson FROM space_memberships sm
     JOIN spaces s ON s.id = sm.space_id WHERE sm.space_id = ?1 AND sm.user_id = ?2`,
  )
    .bind(spaceId, userId)
    .first<{ role: string; settingsJson: string }>();
  if (!row) throw new HttpError(403, "Space membership is required");
  return {
    role: row.role,
    rights: spaceMemberPermissions(row.role, row.settingsJson, userId),
    settingsJson: row.settingsJson,
  };
}

export async function requireSpaceRight(
  env: SecurityEnv,
  context: SecurityContext,
  spaceId: string,
  right: keyof SpaceMemberPermissions,
) {
  const policy = await loadSpacePermissions(env, context.userId, spaceId);
  if (!policy.rights[right])
    throw new HttpError(403, "Space permission is required: " + right);
  return policy;
}

export async function requireWorkflowPermission(
  env: Pick<SecurityEnv, "CONCLAVE_DB">,
  userId: string,
  spaceId: string,
  workflowId: string,
) {
  const policy = await loadSpacePermissions(env, userId, spaceId);
  const chat = workflowId === "chat";
  if (!(chat ? policy.rights.chat : policy.rights.work)) {
    throw new HttpError(
      403,
      chat
        ? "Chat is not allowed for this member"
        : "Work workflows are disabled or not allowed for this member",
    );
  }
  const configuration = await loadSpaceWorkflowConfigurations(
    env,
    spaceId,
    workflowId,
  );
  if (configuration.configurations[0]?.enabled === false)
    throw new HttpError(403, "Workflow is disabled in this Space");
  return policy;
}

export function permissionJsonPath(group: string, id: string): string {
  return "$." + group + "." + JSON.stringify(id);
}
