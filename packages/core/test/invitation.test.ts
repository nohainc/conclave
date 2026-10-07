import { describe, expect, it } from "vitest";
import {
  INVITATION_STATUSES,
  normalizeInvitationEmail,
  isInvitationTerminal,
  isInvitationActive,
  canTransitionInvitation,
  validateInvitationTransition,
  validateInvitationCreation,
} from "../src/invitation.js";
import { DomainInvariantError } from "../src/domain-error.js";

describe("invitation domain", () => {
  describe("email normalization", () => {
    it("normalizes and trims emails correctly", () => {
      expect(normalizeInvitationEmail("  User@Example.COM  ")).toBe(
        "user@example.com",
      );
      expect(normalizeInvitationEmail("ulikossnokia@gmail.com")).toBe(
        "ulikossnokia@gmail.com",
      );
    });

    it("rejects invalid emails", () => {
      expect(() => normalizeInvitationEmail("")).toThrow(DomainInvariantError);
      expect(() => normalizeInvitationEmail("notanemail")).toThrow(
        DomainInvariantError,
      );
      expect(() => normalizeInvitationEmail("user@ domain.com")).toThrow(
        DomainInvariantError,
      );
      expect(() => normalizeInvitationEmail(null as unknown as string)).toThrow(
        DomainInvariantError,
      );
    });
  });

  describe("lifecycle states and transitions", () => {
    it("recognizes all standard lifecycle statuses", () => {
      expect(INVITATION_STATUSES).toEqual([
        "pending",
        "accepted",
        "declined",
        "revoked",
        "expired",
      ]);
    });

    it("identifies terminal states", () => {
      expect(isInvitationTerminal("pending")).toBe(false);
      expect(isInvitationTerminal("accepted")).toBe(true);
      expect(isInvitationTerminal("declined")).toBe(true);
      expect(isInvitationTerminal("revoked")).toBe(true);
      expect(isInvitationTerminal("expired")).toBe(true);
    });

    it("evaluates active status with expiration time", () => {
      const future = new Date(Date.now() + 100000).toISOString();
      const past = new Date(Date.now() - 100000).toISOString();

      expect(
        isInvitationActive({ status: "pending", expiresAt: future }),
      ).toBe(true);
      expect(
        isInvitationActive({ status: "pending", expiresAt: past }),
      ).toBe(false);
      expect(
        isInvitationActive({ status: "accepted", expiresAt: future }),
      ).toBe(false);
      expect(
        isInvitationActive({ status: "declined", expiresAt: future }),
      ).toBe(false);
    });

    it("permits transitions from pending to terminal states only", () => {
      expect(canTransitionInvitation("pending", "accepted")).toBe(true);
      expect(canTransitionInvitation("pending", "declined")).toBe(true);
      expect(canTransitionInvitation("pending", "revoked")).toBe(true);
      expect(canTransitionInvitation("pending", "expired")).toBe(true);

      expect(canTransitionInvitation("pending", "pending")).toBe(false);
      expect(canTransitionInvitation("accepted", "declined")).toBe(false);
      expect(canTransitionInvitation("declined", "accepted")).toBe(false);
      expect(canTransitionInvitation("revoked", "accepted")).toBe(false);
      expect(canTransitionInvitation("expired", "accepted")).toBe(false);
    });

    it("validates valid transitions without error", () => {
      expect(() =>
        validateInvitationTransition("pending", "accepted"),
      ).not.toThrow();
      expect(() =>
        validateInvitationTransition("pending", "declined"),
      ).not.toThrow();
    });

    it("throws on invalid lifecycle transitions", () => {
      expect(() =>
        validateInvitationTransition("accepted", "declined"),
      ).toThrow(DomainInvariantError);
      expect(() =>
        validateInvitationTransition("declined", "accepted"),
      ).toThrow(DomainInvariantError);
      expect(() =>
        validateInvitationTransition("expired", "accepted"),
      ).toThrow(DomainInvariantError);
    });
  });

  describe("creation validation", () => {
    it("accepts valid invitation parameters", () => {
      expect(() =>
        validateInvitationCreation({
          projectId: "proj-1",
          email: "ulikossnokia@gmail.com",
          role: "collaborator",
          invitedByUserId: "user-vitalii",
          expiresAt: new Date(Date.now() + 86400000).toISOString(),
        }),
      ).not.toThrow();
    });

    it("rejects invalid roles or missing fields", () => {
      expect(() =>
        validateInvitationCreation({
          projectId: "",
          email: "valid@example.com",
          role: "collaborator",
          invitedByUserId: "u1",
        }),
      ).toThrow(DomainInvariantError);

      expect(() =>
        validateInvitationCreation({
          projectId: "proj-1",
          email: "valid@example.com",
          role: "owner", // owner cannot be invited
          invitedByUserId: "u1",
        }),
      ).toThrow(DomainInvariantError);

      expect(() =>
        validateInvitationCreation({
          projectId: "proj-1",
          email: "invalid-email",
          role: "collaborator",
          invitedByUserId: "u1",
        }),
      ).toThrow(DomainInvariantError);
    });
  });
});
