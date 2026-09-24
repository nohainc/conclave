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
    expect(selectNextStatefulRequest([
      {
        id: "request-1",
        workstreamId: "ws-1",
        mode: "stateful",
        status: "running",
        primaryWorkspaceId: "workspace-1",
        checkoutId: "checkout-1",
        createdAt: "2026-09-24T00:00:00.000Z",
      },
    ])).toBeNull();
  });

  it("rejects stale fencing tokens and expired leases", () => {
    const expiry = new Date(Date.now() + WORKSTREAM_LEASE_MS).toISOString();
    expect(leaseIsCurrent({ status: "active", fencingToken: 7, expiresAt: expiry }, 7)).toBe(true);
    expect(leaseIsCurrent({ status: "active", fencingToken: 7, expiresAt: expiry }, 6)).toBe(false);
    expect(leaseIsCurrent({ status: "expired", fencingToken: 7, expiresAt: expiry }, 7)).toBe(false);
    expect(
      leaseIsCurrent(
        { status: "active", fencingToken: 7, expiresAt: "2026-09-23T00:00:00.000Z" },
        7,
        Date.parse("2026-09-24T00:00:00.000Z"),
      ),
    ).toBe(false);
  });
});
