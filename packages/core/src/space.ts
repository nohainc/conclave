/** Current space membership vocabulary. */

import { DomainInvariantError } from "./domain-error.js";

export type SpaceRole = "owner" | "collaborator" | "viewer";

/** A person participating in a Space; this does not grant Workspace access. */
export interface SpaceMembership {
  readonly id: string;
  readonly spaceId: string;
  readonly userId: string;
  readonly role: SpaceRole;
  readonly permissions?: {
    readonly chat: boolean;
    readonly work: boolean;
    readonly manageOwnThreads: boolean;
  };
  readonly createdAt: string;
  readonly updatedAt: string;
}

export function validateSpaceMemberships(
  spaceId: string,
  memberships: readonly SpaceMembership[],
): void {
  if (!spaceId.trim()) throw new DomainInvariantError("Space id is required");
  if (memberships.some((membership) => membership.spaceId !== spaceId)) {
    throw new DomainInvariantError(
      "SpaceMembership references a different Space",
    );
  }
  if (
    new Set(memberships.map((membership) => membership.userId)).size !==
    memberships.length
  ) {
    throw new DomainInvariantError(
      "SpaceMembership userId must be unique within a Space",
    );
  }
  if (
    memberships.filter((membership) => membership.role === "owner").length !== 1
  ) {
    throw new DomainInvariantError("Space must have exactly one owner");
  }
}
