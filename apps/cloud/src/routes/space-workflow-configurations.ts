import { loadWorkflowWorkspace } from "./workflow-workspace.js";
import type { SecurityEnv } from "./http-security.js";
import { HttpError } from "./http-security.js";

/** All members execute the same Space configuration, seeded by its owner's globals. */
export async function loadSpaceWorkflowConfigurations(
  env: Pick<SecurityEnv, "CONCLAVE_DB">,
  spaceId: string,
  workflowId?: string,
) {
  const space = await env.CONCLAVE_DB.prepare(
    "SELECT owner_user_id AS ownerUserId FROM spaces WHERE id = ?1",
  )
    .bind(spaceId)
    .first<{ ownerUserId: string }>();
  if (!space) throw new HttpError(404, "Space not found");
  const workspace = await loadWorkflowWorkspace(
    env,
    space.ownerUserId,
    spaceId,
  );
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT workflow_id, configuration_json FROM user_workflow_configurations WHERE user_id = ?1 AND (?2 IS NULL OR workflow_id = ?2) AND NOT EXISTS (SELECT 1 FROM space_workflow_settings WHERE space_id = ?3)
    UNION ALL SELECT workflow_id, configuration_json FROM space_workflow_configurations WHERE space_id = ?3 AND (?2 IS NULL OR workflow_id = ?2)`,
  )
    .bind(space.ownerUserId, workflowId ?? null, spaceId)
    .all<{ workflow_id: string; configuration_json: string }>();
  // Space rows deliberately replace an entire workflow, including Automatic fields.
  const configurations = new Map(
    rows.results.map((row) => [
      row.workflow_id,
      JSON.parse(row.configuration_json),
    ]),
  );
  return {
    ...workspace,
    ownerUserId: space.ownerUserId,
    configurations: [...configurations.values()],
  };
}
