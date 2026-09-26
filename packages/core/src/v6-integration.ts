/** Canonical v6 Workstream integration state machine. */

export type IntegrationStatus =
  | "draft"
  | "branch_published"
  | "pr_open"
  | "merge_ready"
  | "merged"
  | "patch_exported"
  | "completed"
  | "conflict"
  | "failed";

export type IntegrationAction =
  | {
      readonly type: "publish_branch";
      readonly branchName: string;
      readonly headRevision: string;
    }
  | {
      readonly type: "create_pr";
      readonly title: string;
      readonly body: string;
      readonly url: string;
      readonly number: number;
      readonly baseRevision: string;
    }
  | { readonly type: "mark_merge_ready"; readonly baseRevision: string }
  | {
      readonly type: "merge";
      readonly mergeRevision: string;
      readonly baseRevision: string;
    }
  | { readonly type: "export_patch"; readonly artifactId: string }
  | { readonly type: "complete" }
  | { readonly type: "conflict"; readonly reason: string }
  | { readonly type: "fail"; readonly reason: string };

export interface WorkstreamIntegration {
  readonly id: string;
  readonly projectId: string;
  readonly workstreamId: string;
  readonly requestedByUserId: string;
  readonly provider: "github" | "patch";
  readonly status: IntegrationStatus;
  readonly branchName: string | null;
  readonly baseRevision: string;
  readonly headRevision: string | null;
  readonly pullRequestNumber: number | null;
  readonly pullRequestUrl: string | null;
  readonly patchArtifactId: string | null;
  readonly error: string | null;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface IntegrationAuthorization {
  readonly projectRole: "owner" | "collaborator" | "viewer";
  readonly allowedByWorkstreamPolicy: boolean;
}

export function canManageWorkstreamIntegration(
  authorization: IntegrationAuthorization,
): boolean {
  return (
    authorization.allowedByWorkstreamPolicy &&
    authorization.projectRole === "owner"
  );
}

function requireValue(value: string, label: string): void {
  if (!value.trim()) throw new Error(`${label} is required`);
}

export function applyIntegrationAction(
  integration: WorkstreamIntegration,
  action: IntegrationAction,
): WorkstreamIntegration {
  const updatedAt = new Date().toISOString();
  switch (action.type) {
    case "publish_branch":
      requireValue(action.branchName, "branch name");
      requireValue(action.headRevision, "head revision");
      if (
        integration.status !== "draft" &&
        integration.status !== "branch_published"
      ) {
        throw new Error(`Cannot publish branch from ${integration.status}`);
      }
      return {
        ...integration,
        status: "branch_published",
        branchName: action.branchName,
        headRevision: action.headRevision,
        error: null,
        updatedAt,
      };
    case "create_pr":
      requireValue(action.title, "PR title");
      requireValue(action.url, "PR URL");
      if (
        integration.status !== "branch_published" &&
        integration.status !== "pr_open"
      ) {
        throw new Error(`Cannot create PR from ${integration.status}`);
      }
      if (action.baseRevision !== integration.baseRevision) {
        return {
          ...integration,
          status: "conflict",
          error: "Project base moved before PR creation",
          updatedAt,
        };
      }
      if (!Number.isInteger(action.number) || action.number <= 0) {
        throw new Error("PR number must be positive");
      }
      return {
        ...integration,
        status: "pr_open",
        pullRequestNumber: action.number,
        pullRequestUrl: action.url,
        error: null,
        updatedAt,
      };
    case "mark_merge_ready":
      if (integration.status !== "pr_open")
        throw new Error(`Cannot mark merge ready from ${integration.status}`);
      if (action.baseRevision !== integration.baseRevision) {
        return {
          ...integration,
          status: "conflict",
          error: "Project base moved before merge",
          updatedAt,
        };
      }
      return { ...integration, status: "merge_ready", error: null, updatedAt };
    case "merge":
      if (integration.status !== "merge_ready")
        throw new Error(`Cannot merge from ${integration.status}`);
      if (action.baseRevision !== integration.baseRevision) {
        return {
          ...integration,
          status: "conflict",
          error: "Merge conflict: Project base moved",
          updatedAt,
        };
      }
      requireValue(action.mergeRevision, "merge revision");
      return {
        ...integration,
        status: "merged",
        headRevision: action.mergeRevision,
        error: null,
        updatedAt,
      };
    case "export_patch":
      requireValue(action.artifactId, "patch artifact ID");
      if (
        integration.status !== "branch_published" &&
        integration.status !== "pr_open" &&
        integration.status !== "conflict"
      ) {
        throw new Error(`Cannot export patch from ${integration.status}`);
      }
      return {
        ...integration,
        status: "patch_exported",
        patchArtifactId: action.artifactId,
        error: null,
        updatedAt,
      };
    case "complete":
      if (
        integration.status !== "merged" &&
        integration.status !== "patch_exported"
      ) {
        throw new Error(
          `Cannot complete integration from ${integration.status}`,
        );
      }
      return { ...integration, status: "completed", error: null, updatedAt };
    case "conflict":
      requireValue(action.reason, "conflict reason");
      return {
        ...integration,
        status: "conflict",
        error: action.reason,
        updatedAt,
      };
    case "fail":
      requireValue(action.reason, "failure reason");
      return {
        ...integration,
        status: "failed",
        error: action.reason,
        updatedAt,
      };
  }
}
