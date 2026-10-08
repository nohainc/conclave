import { describe, expect, it } from "vitest";
import {
  validateSpaceMemberships,
  type SpaceMembership,
} from "../src/index.js";

const membership = (
  userId: string,
  role: SpaceMembership["role"],
): SpaceMembership => ({
  id: `membership-${userId}`,
  spaceId: "space-1",
  userId,
  role,
  createdAt: "2026-01-01T00:00:00.000Z",
  updatedAt: "2026-01-01T00:00:00.000Z",
});

describe("Space membership", () => {
  it("requires one owner and unique users within the Space", () => {
    expect(() =>
      validateSpaceMemberships("space-1", [
        membership("owner", "owner"),
        membership("collaborator", "collaborator"),
      ]),
    ).not.toThrow();
    expect(() =>
      validateSpaceMemberships("space-1", [membership("viewer", "viewer")]),
    ).toThrow(/exactly one owner/);
    expect(() =>
      validateSpaceMemberships("space-1", [
        membership("owner", "owner"),
        membership("owner", "collaborator"),
      ]),
    ).toThrow(/unique/);
  });
});
