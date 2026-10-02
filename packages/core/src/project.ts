/** Current project membership vocabulary. */

import { DomainInvariantError } from "./domain-error.js";

export type ProjectRole = "owner" | "collaborator" | "viewer";

/** A person participating in a Project; this does not grant Workspace access. */
export interface ProjectMembership {
  readonly id: string;
  readonly projectId: string;
  readonly userId: string;
  readonly role: ProjectRole;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export function validateProjectMemberships(
  projectId: string,
  memberships: readonly ProjectMembership[],
): void {
  if (!projectId.trim())
    throw new DomainInvariantError("Project id is required");
  if (memberships.some((membership) => membership.projectId !== projectId)) {
    throw new DomainInvariantError(
      "ProjectMembership references a different Project",
    );
  }
  if (
    new Set(memberships.map((membership) => membership.userId)).size !==
    memberships.length
  ) {
    throw new DomainInvariantError(
      "ProjectMembership userId must be unique within a Project",
    );
  }
  if (
    memberships.filter((membership) => membership.role === "owner").length !== 1
  ) {
    throw new DomainInvariantError("Project must have exactly one owner");
  }
}
