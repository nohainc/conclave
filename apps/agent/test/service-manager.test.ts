import { describe, expect, it } from "vitest";
import { LAUNCH_AGENT_LABEL, launchAgentPlist } from "../src/service-manager.js";

describe("macOS launch agent", () => {
  it("renders a user-scoped, restartable service with isolated logs", () => {
    const plist = launchAgentPlist({ executable: "/usr/local/bin/conclave-agent", homeDir: "/tmp/agent", logDir: "/tmp/agent/logs" });
    expect(plist).toContain(`<key>Label</key><string>${LAUNCH_AGENT_LABEL}</string>`);
    expect(plist).toContain("<key>RunAtLoad</key><true/>");
    expect(plist).toContain("<key>KeepAlive</key><true/>");
    expect(plist).toContain("launchd.stdout.log");
    expect(plist).toContain("/usr/local/bin/conclave-agent");
  });
});

