import { describe, expect, it } from "vitest";
import {
  validateProjectMemberships,
  type ProjectMembership,
} from "../src/index.js";

const membership = (
  userId: string,
  role: ProjectMembership["role"],
): ProjectMembership => ({
  id: `membership-${userId}`,
  projectId: "project-1",
  userId,
  role,
  createdAt: "2026-01-01T00:00:00.000Z",
  updatedAt: "2026-01-01T00:00:00.000Z",
});

describe("Project membership", () => {
  it("requires one owner and unique users within the Project", () => {
    expect(() =>
      validateProjectMemberships("project-1", [
        membership("owner", "owner"),
        membership("collaborator", "collaborator"),
      ]),
    ).not.toThrow();
    expect(() =>
      validateProjectMemberships("project-1", [membership("viewer", "viewer")]),
    ).toThrow(/exactly one owner/);
    expect(() =>
      validateProjectMemberships("project-1", [
        membership("owner", "owner"),
        membership("owner", "collaborator"),
      ]),
    ).toThrow(/unique/);
  });
});
