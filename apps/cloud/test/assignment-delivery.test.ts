import { expect, it } from "vitest";
import {
  assignmentCommandDisposition,
  assignmentDeliveryExpired,
} from "../src/assignment-delivery.js";

it("classifies redispatch without reopening terminal state", () => {
  expect(assignmentCommandDisposition("created")).toEqual({
    shouldSend: true,
    duplicate: false,
    terminal: false,
    accepted: false,
  });
  expect(assignmentCommandDisposition("dispatched").duplicate).toBe(true);
  expect(assignmentCommandDisposition("running")).toEqual({
    shouldSend: false,
    duplicate: true,
    terminal: false,
    accepted: true,
  });
  expect(assignmentCommandDisposition("completed")).toEqual({
    shouldSend: false,
    duplicate: true,
    terminal: true,
    accepted: true,
  });
});
it("bounds unacknowledged delivery without limiting provider execution", () => {
  const started = "2026-10-05T14:00:00.000Z";
  expect(
    assignmentDeliveryExpired(
      "dispatched",
      started,
      Date.parse(started) + 29_999,
    ),
  ).toBe(false);
  expect(
    assignmentDeliveryExpired(
      "dispatched",
      started,
      Date.parse(started) + 30_000,
    ),
  ).toBe(true);
  expect(
    assignmentDeliveryExpired(
      "acknowledged",
      started,
      Date.parse(started) + 29_999,
      30_000,
    ),
  ).toBe(false);
  expect(
    assignmentDeliveryExpired(
      "acknowledged",
      started,
      Date.parse(started) + 30_000,
      30_000,
    ),
  ).toBe(true);
  for (const status of ["running", "completed", "failed", "cancelled"]) {
    expect(
      assignmentDeliveryExpired(status, started, Date.parse(started) + 900_000),
    ).toBe(false);
  }
});
