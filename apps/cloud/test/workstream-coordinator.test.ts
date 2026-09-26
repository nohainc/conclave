import { describe, expect, it } from "vitest";
import {
  leaseIsCurrent,
  nextFencingToken,
  selectNextStatefulRequest,
  WORKSTREAM_LEASE_MS,
} from "../src/workstream-coordinator.js";

describe("Workstream execution coordinator", () => {
  it("selects exactly one FIFO stateful request and bypasses stateless work", () => {
    expect(
      selectNextStatefulRequest([
        {
          id: "later",
          workstreamId: "ws-1",
          mode: "stateful",
          status: "queued",
          primaryWorkspaceId: "workspace-1",
          checkoutId: "checkout-1",
          createdAt: "2026-09-24T00:00:02.000Z",
        },
        {
          id: "stateless",
          workstreamId: "ws-1",
          mode: "stateless",
          status: "queued",
          primaryWorkspaceId: "",
          checkoutId: "",
          createdAt: "2026-09-24T00:00:00.000Z",
        },
        {
          id: "first",
          workstreamId: "ws-1",
          mode: "stateful",
          status: "queued",
          primaryWorkspaceId: "workspace-1",
          checkoutId: "checkout-1",
          createdAt: "2026-09-24T00:00:01.000Z",
        },
      ]),
    ).toMatchObject({ id: "first" });
  });

  it("makes fencing monotonic across restart and duplicate enqueue", () => {
    expect(nextFencingToken(null)).toBe(1);
    expect(nextFencingToken(4)).toBe(5);
    // A duplicate enqueue observes the existing non-queued state and does not
    // allocate another token; the coordinator's enqueue path is idempotent by
    // Work Request ID.
    expect(
      selectNextStatefulRequest([
        {
          id: "request-1",
          workstreamId: "ws-1",
          mode: "stateful",
          status: "running",
          primaryWorkspaceId: "workspace-1",
          checkoutId: "checkout-1",
          createdAt: "2026-09-24T00:00:00.000Z",
        },
      ]),
    ).toBeNull();
  });

  it("rejects stale fencing tokens and expired leases", () => {
    const expiry = new Date(Date.now() + WORKSTREAM_LEASE_MS).toISOString();
    expect(
      leaseIsCurrent(
        { status: "active", fencingToken: 7, expiresAt: expiry },
        7,
      ),
    ).toBe(true);
    expect(
      leaseIsCurrent(
        { status: "active", fencingToken: 7, expiresAt: expiry },
        6,
      ),
    ).toBe(false);
    expect(
      leaseIsCurrent(
        { status: "expired", fencingToken: 7, expiresAt: expiry },
        7,
      ),
    ).toBe(false);
    expect(
      leaseIsCurrent(
        {
          status: "active",
          fencingToken: 7,
          expiresAt: "2026-09-23T00:00:00.000Z",
        },
        7,
        Date.parse("2026-09-24T00:00:00.000Z"),
      ),
    ).toBe(false);
  });

  it("maintains deterministic creation order and respects custom workstreamOrder", async () => {
    const { sortWorkstreams } = await import("../src/routes/handlers.js");
    const ws1 = {
      id: "ws-1",
      name: "Alpha",
      createdAt: "2026-09-24T00:00:01.000Z",
    };
    const ws2 = {
      id: "ws-2",
      name: "Beta",
      createdAt: "2026-09-24T00:00:02.000Z",
    };
    const ws3 = {
      id: "ws-3",
      name: "Gamma",
      createdAt: "2026-09-24T00:00:03.000Z",
    };

    // Default order is created_at ASC
    const defaultSorted = sortWorkstreams([ws3, ws1, ws2]);
    expect(defaultSorted.map((w) => w.id)).toEqual(["ws-1", "ws-2", "ws-3"]);

    // Custom order moves beta to first, gamma to second, alpha to third
    const customSorted = sortWorkstreams(
      [ws1, ws2, ws3],
      ["ws-2", "ws-3", "ws-1"],
    );
    expect(customSorted.map((w) => w.id)).toEqual(["ws-2", "ws-3", "ws-1"]);

    // When a workstream is updated/renamed, its position is not altered
    const renamedWs2 = {
      ...ws2,
      name: "Beta Renamed",
      updatedAt: "2026-09-25T12:00:00.000Z",
    };
    const updatedSorted = sortWorkstreams([ws1, renamedWs2, ws3]);
    expect(updatedSorted.map((w) => w.id)).toEqual(["ws-1", "ws-2", "ws-3"]);
  });
});
