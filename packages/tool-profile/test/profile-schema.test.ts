/* eslint-disable @typescript-eslint/no-explicit-any -- these tests mutate arbitrary JSON fixtures. */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  parseToolProfileV1,
  TOOL_PROFILE_LIMITS,
  toolProfileV1JsonSchema,
  toolProfileV1Schema,
} from "../src/index.js";

const fixture = (name: string): Record<string, any> =>
  JSON.parse(
    readFileSync(
      fileURLToPath(new URL(`./fixtures/${name}.json`, import.meta.url)),
      "utf8",
    ),
  );

describe("Tool Profile v1 canonical schema", () => {
  it.each(["chatgpt-codex.v1", "gemini-antigravity.v1", "fixture-cli.v1"])(
    "accepts the complete %s fixture",
    (name) => {
      expect(parseToolProfileV1(fixture(name)).schemaVersion).toBe(1);
    },
  );

  it("exports a strict JSON Schema and inferred model from the same source", () => {
    expect(toolProfileV1JsonSchema.type).toBe("object");
    expect(toolProfileV1JsonSchema.additionalProperties).toBe(false);
    expect(TOOL_PROFILE_LIMITS.arguments).toBe(128);
  });

  it("allows provider compatibility to remain incomplete in an unsigned Draft", () => {
    const draft = fixture("fixture-cli.v1");
    draft.providerTool.supportedVersions = [];
    expect(parseToolProfileV1(draft).providerTool.supportedVersions).toEqual(
      [],
    );
  });

  const invalidCases: Array<[string, (profile: Record<string, any>) => void]> =
    [
      [
        "identity",
        (p) => {
          p.schemaVersion = 2;
        },
      ],
      [
        "top-level unknown fields",
        (p) => {
          p.extra = true;
        },
      ],
      [
        "engine compatibility",
        (p) => {
          p.engineCompatibility.maxExclusive = "1.0.0";
        },
      ],
      [
        "provider tool",
        (p) => {
          p.providerTool.name = "";
        },
      ],
      [
        "discovery",
        (p) => {
          p.providerTool.executableCandidates = ["../codex"];
        },
      ],
      [
        "array bound",
        (p) => {
          p.providerTool.discovery.standardLocations = Array.from(
            { length: TOOL_PROFILE_LIMITS.arrayItems + 1 },
            () => "{{home}}/.local/bin",
          );
        },
      ],
      [
        "version probe and pattern IDs",
        (p) => {
          p.providerTool.versionProbe.extract.patternId = "custom_regex";
        },
      ],
      [
        "environment names",
        (p) => {
          p.environment.passthrough.push("CONCLAVE_TOKEN");
        },
      ],
      [
        "environment name count",
        (p) => {
          p.environment.passthrough = Array.from(
            { length: TOOL_PROFILE_LIMITS.environmentNames + 1 },
            (_, i) => `ENV_${i}`,
          );
        },
      ],
      [
        "string bound",
        (p) => {
          p.environment.set.NO_COLOR = "x".repeat(
            TOOL_PROFILE_LIMITS.stringLength + 1,
          );
        },
      ],
      [
        "passive probe",
        (p) => {
          p.probe.passive.checks.push({
            id: "strange",
            arguments: ["x"],
            timeoutMs: 10000,
            successExitCodes: [0],
            failureIssueCode: "not_an_issue",
          });
        },
      ],
      [
        "bounded config read",
        (p) => {
          p.probe.passive.configChecks = [
            {
              id: "escape",
              root: "home",
              relativePath: "../../secrets",
              format: "json",
              maxBytes: 100,
              onMissing: "warning",
              onInvalid: "failed",
              rules: [],
            },
          ];
        },
      ],
      [
        "argument bounds",
        (p) => {
          p.execution.arguments = Array.from(
            { length: TOOL_PROFILE_LIMITS.arguments + 1 },
            () => "x",
          );
        },
      ],
      [
        "required interpreter insertion slots",
        (p) => {
          p.execution.arguments = p.execution.arguments.filter(
            (part: unknown) =>
              typeof part !== "object" ||
              part === null ||
              !("providerTimeoutArguments" in part),
          );
        },
      ],
      [
        "event rule count",
        (p) => {
          p.execution.events = Array.from(
            { length: TOOL_PROFILE_LIMITS.eventRules + 1 },
            () => p.execution.events[0],
          );
        },
      ],
      [
        "stdin",
        (p) => {
          p.execution.stdin = { mode: "shell", value: "echo unsafe" };
        },
      ],
      [
        "output",
        (p) => {
          p.execution.output.mode = "yaml";
        },
      ],
      [
        "selector syntax",
        (p) => {
          p.execution.events[0].when[0].selector = "$..thread_id";
        },
      ],
      [
        "selector prototype properties",
        (p) => {
          p.session.extract = "$.constructor";
        },
      ],
      [
        "selector depth",
        (p) => {
          p.session.extract = `$.${Array.from({ length: TOOL_PROFILE_LIMITS.selectorDepth + 1 }, (_, i) => `a${i}`).join(".")}`;
        },
      ],
      [
        "JSON stdin nesting depth",
        (p) => {
          const nested = Array.from({
            length: TOOL_PROFILE_LIMITS.selectorDepth + 1,
          }).reduceRight((child: any) => ({ nested: child }), {
            leaf: "value",
          });
          p.execution.stdin = {
            mode: "json_object",
            value: { nested },
            appendNewline: true,
          };
        },
      ],
      [
        "placeholder set",
        (p) => {
          p.execution.arguments.push("{{shellCommand}}");
        },
      ],
      [
        "event action",
        (p) => {
          p.execution.events[0].actions[0].type = "run_command";
        },
      ],
      [
        "session consistency",
        (p) => {
          p.session.supported = false;
        },
      ],
      [
        "session format compatibility declaration",
        (p) => {
          p.session.compatibleFormatIds = ["codex-thread-v2"];
        },
      ],
      [
        "unique session format compatibility IDs",
        (p) => {
          p.session.compatibleFormatIds.push(p.session.formatId);
        },
      ],
      [
        "model policy",
        (p) => {
          p.model.unknownModelPolicy = "profile_allowlist";
        },
      ],
      [
        "timeout",
        (p) => {
          p.timeout.providerReserveMs = 30001;
        },
      ],
      [
        "sandbox mappings",
        (p) => {
          p.sandbox.mappings.arbitrary = ["--unsafe"];
        },
      ],
      [
        "progress rule count",
        (p) => {
          p.progress = Array.from(
            { length: TOOL_PROFILE_LIMITS.progressRules + 1 },
            () => p.progress[0],
          );
        },
      ],
      [
        "error mapping",
        (p) => {
          p.errors.mappings[0].evidence.patternId = "user_regex";
        },
      ],
      [
        "version pattern used for stderr",
        (p) => {
          p.errors.mappings[0].evidence.patternId = "semver";
        },
      ],
      [
        "capability",
        (p) => {
          p.capabilities.push("arbitrary_shell");
        },
      ],
      [
        "compatibility override overlap",
        (p) => {
          p.compatibilityOverrides.push({
            providerVersion: { min: "0.180.5", maxExclusive: "0.182.0" },
            executionArguments: ["x"],
          });
        },
      ],
      [
        "compatibility override count",
        (p) => {
          p.compatibilityOverrides = Array.from(
            { length: TOOL_PROFILE_LIMITS.compatibilityOverrides + 1 },
            (_, i) => ({
              providerVersion: {
                min: `${i + 1}.0.0`,
                maxExclusive: `${i + 1}.1.0`,
              },
            }),
          );
        },
      ],
      [
        "unknown nested fields",
        (p) => {
          p.providerTool.discovery.extra = true;
        },
      ],
      [
        "Profile-controlled live prompt expectations",
        (p) => {
          (p.probe as Record<string, unknown>).live = {
            timeoutMs: 60_000,
            expectedFinalText: { kind: "exact", value: "READY" },
          };
        },
      ],
    ];

  it.each(invalidCases)("rejects invalid %s fixtures", (_section, mutate) => {
    const invalid = fixture("chatgpt-codex.v1");
    mutate(invalid);
    expect(() => parseToolProfileV1(invalid)).toThrow();
  });

  it("exposes the strict canonical validator", () => {
    expect(
      toolProfileV1Schema.safeParse(fixture("chatgpt-codex.v1")).success,
    ).toBe(true);
  });

  it("keeps v1 closed to speculative versions, scripts, and expressions", () => {
    const futureVersion = fixture("fixture-cli.v1");
    futureVersion.schemaVersion = 2;
    expect(() => parseToolProfileV1(futureVersion)).toThrow();

    const scripted = fixture("fixture-cli.v1");
    scripted.execution.script = "run arbitrary code";
    expect(() => parseToolProfileV1(scripted)).toThrow();

    const expressed = fixture("fixture-cli.v1");
    expressed.execution.arguments.push("{{prompt | execute}}");
    expect(() => parseToolProfileV1(expressed)).toThrow();
  });

  it("rejects an oversized serialized profile", () => {
    const valid = JSON.stringify(fixture("chatgpt-codex.v1"));
    expect(() =>
      parseToolProfileV1(
        `${valid}${" ".repeat(TOOL_PROFILE_LIMITS.payloadBytes)}`,
      ),
    ).toThrow(/exceeds/);
  });
});
