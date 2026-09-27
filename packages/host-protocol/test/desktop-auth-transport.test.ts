import { describe, expect, it } from "vitest";
import {
  DESKTOP_AUTH_TRANSPORT_VERSION,
  DesktopHumanSessionCredentialSchema,
  DesktopAuthIntentClaimRequestSchema,
  RuntimePollRequestSchema,
  RuntimePollResponseSchema,
  RuntimeTransportStatusSchema,
  WorkspaceRegistrationRequestSchema,
  WorkspaceRuntimeCredentialSchema,
} from "../src/index.js";

const timestamp = "2026-09-27T12:00:00.000Z";

describe("desktop auth and runtime transport contracts", () => {
  it("keeps human and runtime credentials as distinct typed secrets", () => {
    expect(DesktopHumanSessionCredentialSchema.parse("h".repeat(32))).toBe(
      "h".repeat(32),
    );
    expect(WorkspaceRuntimeCredentialSchema.parse("r".repeat(32))).toBe(
      "r".repeat(32),
    );
    expect(DesktopHumanSessionCredentialSchema.safeParse("short").success).toBe(
      false,
    );
  });

  it("requires the separate poll secret for one-time intent claim", () => {
    expect(
      DesktopAuthIntentClaimRequestSchema.safeParse({
        intentId: "intent-1",
        pollToken: "p".repeat(32),
      }).success,
    ).toBe(true);
    expect(
      DesktopAuthIntentClaimRequestSchema.safeParse({ intentId: "intent-1" })
        .success,
    ).toBe(false);
  });

  it("validates versioned installation registration data", () => {
    expect(
      WorkspaceRegistrationRequestSchema.parse({
        contractVersion: DESKTOP_AUTH_TRANSPORT_VERSION,
        installationId: "install_00000000-0000-4000-8000-000000000001",
        proposedWorkspaceName: "Studio",
        hostname: "studio.local",
        platform: "macos",
        architecture: "arm64",
        appVersion: "1.2.3",
        runtimeCapabilities: { os: "macos", arch: "arm64", appVersion: "1.2.3", supportedRuntimes: ["dart"], maxConcurrentWorkers: 1 },
      }).installationId,
    ).toContain("install_00000000");
    expect(
      WorkspaceRegistrationRequestSchema.safeParse({
        contractVersion: DESKTOP_AUTH_TRANSPORT_VERSION,
        installationId: "bad",
        proposedWorkspaceName: "Studio",
        hostname: "studio.local",
        platform: "macos",
        architecture: "arm64",
        appVersion: "1.2.3",
        runtimeCapabilities: [],
      }).success,
    ).toBe(false);
  });

  it("bounds cursor-based long polling and event batches", () => {
    expect(
      RuntimePollRequestSchema.parse({
        sessionId: "session-1",
        cursor: "cursor-2",
        waitMs: 25000,
      }).cursor,
    ).toBe("cursor-2");
    expect(
      RuntimePollRequestSchema.safeParse({
        sessionId: "session-1",
        cursor: "cursor-2",
        waitMs: 90000,
      }).success,
    ).toBe(false);
    expect(
      RuntimePollResponseSchema.parse({
        cursor: "cursor-3",
        events: [],
        serverTime: timestamp,
        timedOut: true,
      }).events,
    ).toEqual([]);
  });

  it("projects degraded fallback separately from authentication failure", () => {
    const status = {
      state: "fallback_ready",
      activeTransport: "http_long_poll",
      preferredTransport: "websocket",
      lastWebSocketFailure: {
        code: "upgrade_failed",
        message: "Proxy rejected upgrade",
        occurredAt: timestamp,
      },
      fallbackSessionId: "session-1",
      lastPollAt: timestamp,
      lastRuntimeEventAt: null,
      observedAt: timestamp,
    };
    expect(RuntimeTransportStatusSchema.parse(status).state).toBe(
      "fallback_ready",
    );
    expect(
      RuntimeTransportStatusSchema.safeParse({
        ...status,
        state: "authentication_required",
        activeTransport: "http_long_poll",
      }).success,
    ).toBe(false);
  });
});
