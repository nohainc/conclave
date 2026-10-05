import { expect, it } from "vitest";
import { assignmentDeliveryExpired } from "../src/assignment-delivery.js";
it("bounds unacknowledged delivery without limiting provider execution", () => {
  const started = "2026-10-05T14:00:00.000Z";
  expect(assignmentDeliveryExpired("dispatched", started, Date.parse(started) + 29_999)).toBe(false);
  expect(assignmentDeliveryExpired("dispatched", started, Date.parse(started) + 30_000)).toBe(true);
  for (const status of ["acknowledged", "running", "completed", "failed", "cancelled"]) {
    expect(assignmentDeliveryExpired(status, started, Date.parse(started) + 900_000)).toBe(false);
  }
});
