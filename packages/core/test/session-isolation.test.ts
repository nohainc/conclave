import { describe, expect, it } from "vitest";
import {
  canReuseWorkerSession,
  createWorkerSessionNamespace,
} from "../src/session-isolation.js";

describe("Worker session isolation", () => {
  const base = {
    workerId: "codex-web",
    credentialProfileId: "profile-a",
    projectId: "project-a",
    mode: "chat" as const,
  };

  it("namespaces simultaneous sessions by Worker, profile, project, mode, and session", () => {
    const first = createWorkerSessionNamespace({ ...base, sessionId: "a" });
    const second = createWorkerSessionNamespace({ ...base, sessionId: "b" });
    expect(first).not.toBe(second);
    expect(first).toContain("profile-a");
    expect(first).toContain("project-a");
  });

  it("does not reuse provider history across users/profiles/projects", () => {
    const first = { ...base, sessionId: "session-a" };
    expect(
      canReuseWorkerSession(first, { ...first, sessionId: "session-b" }),
    ).toBe(false);
    expect(
      canReuseWorkerSession(first, {
        ...first,
        credentialProfileId: "profile-b",
      }),
    ).toBe(false);
    expect(
      canReuseWorkerSession(first, { ...first, projectId: "project-b" }),
    ).toBe(false);
  });

  it("allows reuse only for the same non-fresh namespace", () => {
    const session = { ...base, sessionId: "session-a" };
    expect(canReuseWorkerSession(session, session)).toBe(true);
    expect(
      canReuseWorkerSession(
        { ...session, mode: "fresh" },
        { ...session, mode: "fresh" },
      ),
    ).toBe(false);
  });
});
