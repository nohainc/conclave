import {
  conversationWorkflowForExecution,
  workflowCatalogEntry,
  type BuiltinWorkflowDefinition,
  type TurnExecutionConfig,
} from "@conclave/core";
import { HttpError } from "./http-security.js";

export interface TurnExecutionSelection {
  workerId: string;
  profileId?: string | null;
  profileReleaseVersion?: number | null;
  modelId: string | null;
  effort: string | null;
}

export function parseTurnExecutionSelection(
  value: unknown,
  workflow: BuiltinWorkflowDefinition,
): TurnExecutionSelection | null {
  if (value === undefined) return null;
  if (
    !conversationWorkflowForExecution(workflow.id, workflow.version) ||
    !value ||
    typeof value !== "object" ||
    Array.isArray(value)
  ) {
    throw new HttpError(
      400,
      "executionSelection requires a manual Conversation workflow",
    );
  }
  const input = value as Record<string, unknown>;
  if (
    Object.keys(input).some(
      (key) =>
        ![
          "workerId",
          "profileId",
          "profileReleaseVersion",
          "modelId",
          "effort",
        ].includes(key),
    )
  ) {
    throw new HttpError(400, "executionSelection contains unsupported fields");
  }
  const string = (
    key: string,
    max: number,
    nullable: boolean,
  ): string | null => {
    const raw = input[key];
    if (nullable && (raw === null || raw === undefined)) return null;
    if (typeof raw !== "string" || !raw.trim() || raw.length > max)
      throw new HttpError(400, `executionSelection ${key} is invalid`);
    return raw.trim();
  };
  const policy = workflowCatalogEntry(workflow).executionPolicy;
  const selection = {
    workerId: string("workerId", 200, false)!,
    profileId: string("profileId", 96, true),
    profileReleaseVersion:
      input.profileReleaseVersion == null
        ? null
        : Number(input.profileReleaseVersion),
    modelId: string("modelId", 160, true),
    effort: string("effort", 64, true),
  };
  if (
    selection.profileReleaseVersion !== null &&
    (typeof input.profileReleaseVersion !== "number" ||
      !Number.isSafeInteger(selection.profileReleaseVersion) ||
      selection.profileReleaseVersion < 1)
  )
    throw new HttpError(
      400,
      "executionSelection profileReleaseVersion is invalid",
    );
  if (
    !policy.userSelectsWorker ||
    (selection.modelId !== null && !policy.userSelectsModel) ||
    (selection.effort !== null && !policy.userSelectsEffort)
  )
    throw new HttpError(400, "Workflow does not allow these execution choices");
  return selection;
}

export function resolveTurnExecutionConfig(
  workflow: BuiltinWorkflowDefinition,
  workerId: string,
  profile: { profileId: string; profileReleaseVersion: number } | undefined,
  modelId: string | null,
  effort: string | null,
  selection: TurnExecutionSelection | null,
): TurnExecutionConfig {
  if (
    !workerId ||
    !profile?.profileId ||
    !Number.isSafeInteger(profile.profileReleaseVersion) ||
    profile.profileReleaseVersion < 1
  )
    throw new HttpError(422, "Selected Worker Profile is unavailable");
  if (
    (selection?.profileId && selection.profileId !== profile.profileId) ||
    (selection?.profileReleaseVersion &&
      selection.profileReleaseVersion !== profile.profileReleaseVersion)
  )
    throw new HttpError(
      409,
      "Selected Worker Profile changed; refresh before sending a new request",
    );
  return {
    schemaVersion: 1,
    workerId,
    profileId: profile.profileId,
    profileReleaseVersion: profile.profileReleaseVersion,
    modelId,
    effort,
    workflowId: workflow.id,
    workflowVersion: workflow.version,
  };
}
