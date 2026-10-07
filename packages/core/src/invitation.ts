import { DomainInvariantError } from "./domain-error.js";
import type { ProjectRole } from "./project.js";

export const INVITATION_STATUSES = [
  "pending",
  "accepted",
  "declined",
  "revoked",
  "expired",
] as const;

export type InvitationStatus = (typeof INVITATION_STATUSES)[number];

export const VALID_INVITATION_ROLES: readonly ProjectRole[] = [
  "collaborator",
  "viewer",
] as const;

export interface ProjectInvitation {
  readonly id: string;
  readonly projectId: string;
  readonly email: string;
  readonly role: ProjectRole;
  readonly invitedByUserId: string;
  readonly status: InvitationStatus;
  readonly expiresAt: string;
  readonly acceptedByUserId?: string | null;
  readonly acceptedAt?: string | null;
  readonly respondedAt?: string | null;
  readonly createdAt: string;
  readonly updatedAt: string;
}

const EMAIL_REGEX = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/**
 * Normalizes and validates an invitation email address.
 * Converts to trimmed lowercase, ensuring standard identity matching.
 */
export function normalizeInvitationEmail(rawEmail: string): string {
  if (typeof rawEmail !== "string") {
    throw new DomainInvariantError("Valid invitation email is required");
  }
  const normalized = rawEmail.trim().toLowerCase();
  if (!normalized || !EMAIL_REGEX.test(normalized)) {
    throw new DomainInvariantError(
      `Invalid invitation email address: '${rawEmail}'`,
    );
  }
  return normalized;
}

/**
 * Checks whether an invitation has reached a terminal lifecycle state.
 */
export function isInvitationTerminal(status: InvitationStatus): boolean {
  return status !== "pending";
}

/**
 * Checks whether an invitation is currently active and can be responded to.
 */
export function isInvitationActive(
  invitation: { status: InvitationStatus; expiresAt: string },
  now = new Date().toISOString(),
): boolean {
  if (invitation.status !== "pending") return false;
  const expiryTime = new Date(invitation.expiresAt).getTime();
  const currentTime = new Date(now).getTime();
  return !Number.isNaN(expiryTime) && expiryTime > currentTime;
}

/**
 * Determines whether a lifecycle transition is allowed.
 * Only pending invitations may transition, and all other states are terminal.
 */
export function canTransitionInvitation(
  currentStatus: InvitationStatus,
  targetStatus: InvitationStatus,
): boolean {
  if (currentStatus !== "pending") return false;
  return (
    targetStatus !== "pending" && INVITATION_STATUSES.includes(targetStatus)
  );
}

/**
 * Validates that an invitation lifecycle transition conforms to domain invariants.
 */
export function validateInvitationTransition(
  currentStatus: InvitationStatus,
  targetStatus: InvitationStatus,
): void {
  if (!canTransitionInvitation(currentStatus, targetStatus)) {
    throw new DomainInvariantError(
      `Cannot transition invitation from '${currentStatus}' to '${targetStatus}'`,
    );
  }
}

/**
 * Validates new project invitation creation payload.
 */
export function validateInvitationCreation(params: {
  projectId: string;
  email: string;
  role: string;
  invitedByUserId: string;
  expiresAt?: string;
}): void {
  if (!params.projectId || !params.projectId.trim()) {
    throw new DomainInvariantError("Project ID is required for invitation");
  }
  if (!params.invitedByUserId || !params.invitedByUserId.trim()) {
    throw new DomainInvariantError("Invited by user ID is required");
  }
  if (!VALID_INVITATION_ROLES.includes(params.role as ProjectRole)) {
    throw new DomainInvariantError(
      `Invalid invitation role '${params.role}'. Must be 'collaborator' or 'viewer'`,
    );
  }
  normalizeInvitationEmail(params.email);
  if (params.expiresAt) {
    const expiry = new Date(params.expiresAt).getTime();
    if (Number.isNaN(expiry)) {
      throw new DomainInvariantError("Invalid expiration date format");
    }
  }
}
