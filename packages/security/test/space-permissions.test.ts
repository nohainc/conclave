import { expect, it } from "vitest";
import {
  defaultSpaceMemberPermissions,
  spaceMemberPermissions,
} from "../src/index.js";

it("keeps role defaults only when the override is absent, and fails closed for malformed stored overrides", () => {
  const none = defaultSpaceMemberPermissions("viewer");
  for (const value of [false, null, 0, "", [], "invalid", { chat: "true" }]) {
    expect(
      spaceMemberPermissions(
        "collaborator",
        { memberPermissions: { member: value } },
        "member",
      ),
    ).toEqual(none);
  }
  expect(spaceMemberPermissions("collaborator", {}, "member")).toEqual(
    defaultSpaceMemberPermissions("collaborator"),
  );
  expect(
    spaceMemberPermissions(
      "owner",
      { memberPermissions: { member: none } },
      "member",
    ),
  ).toEqual(defaultSpaceMemberPermissions("owner"));
  expect(
    spaceMemberPermissions(
      "collaborator",
      { memberPermissions: { member: { chat: true } } },
      "member",
    ),
  ).toEqual({ ...none, chat: true });
});
