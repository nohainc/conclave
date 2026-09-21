import { describe, it, expect } from "vitest";
import { AgentCapabilitiesSchema } from "@conclave/agent-protocol";
import { detectAgentCapabilities } from "../src/capabilities.js";
import { loadAgentConfig } from "../src/config.js";

describe("AgentCapabilities", () => {
  it("detects valid host capabilities adhering to AgentCapabilitiesSchema", () => {
    const config = loadAgentConfig({ maxConcurrentWorkers: 6 });
    const caps = detectAgentCapabilities(config);

    expect(["macos", "linux", "windows"]).toContain(caps.os);
    expect(["arm64", "x64"]).toContain(caps.arch);
    expect(caps.agentVersion).toBe("0.2.0");
    expect(caps.maxConcurrentWorkers).toBe(6);
    expect(Array.isArray(caps.supportedRuntimes)).toBe(true);

    const parsed = AgentCapabilitiesSchema.parse(caps);
    expect(parsed).toEqual(caps);
  });
});
