import { readdirSync, readFileSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  extractProfileProviderVersion,
  interpretProfileExecution,
  interpretProfileReadiness,
  parseToolProfileV1,
  type ProfileExecutionContext,
  type ProviderVersionProbeInput,
} from "../src/index.js";

const fixtureRoot = fileURLToPath(
  new URL("./fixtures/profiles/", import.meta.url),
);

interface FixtureManifest {
  schemaVersion: 1;
  profile: string;
  versionCases: Array<{
    name: string;
    fixture: string;
    exitCode: number;
    expected: unknown;
  }>;
  readinessCases: Array<{
    name: string;
    fixture: string;
    input?: {
      versionFixture: string;
      versionExitCode: number;
      commandExitCodes?: Record<string, number>;
      configFiles?: Record<string, string>;
      environment?: Record<string, string>;
    };
    expected: unknown;
  }>;
  executionCases: Array<{
    name: string;
    fixture: string;
    exitCode?: number;
    sessionPolicy: "stateless" | "durable";
    sessionId?: string;
    expected: unknown;
  }>;
}

function readJson(path: string): unknown {
  return JSON.parse(readFileSync(path, "utf8"));
}

function fixturePath(profileDirectory: string, relativePath: string): string {
  const path = resolve(profileDirectory, relativePath);
  const fromRoot = relative(fixtureRoot, path);
  if (fromRoot.startsWith("..") || resolve(fixtureRoot, fromRoot) !== path) {
    throw new Error(`Fixture path escapes fixture root: ${relativePath}`);
  }
  return path;
}

function versionProbe(
  profile: ReturnType<typeof parseToolProfileV1>,
  output: string,
  exitCode: number,
): ProviderVersionProbeInput {
  return profile.providerTool.versionProbe.source === "stderr"
    ? { stdout: "", stderr: output, exitCode }
    : { stdout: output, stderr: "", exitCode };
}

const profileDirectories = readdirSync(fixtureRoot, { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map((entry) => entry.name)
  .sort();

describe("offline Tool Profile release fixtures", () => {
  it("contains only versioned fixture manifests", () => {
    expect(profileDirectories.length).toBeGreaterThan(0);
    for (const directory of profileDirectories) {
      const manifest = readJson(
        resolve(fixtureRoot, directory, "manifest.json"),
      ) as FixtureManifest;
      expect(manifest.schemaVersion).toBe(1);
      expect(manifest.versionCases.length).toBeGreaterThan(0);
      expect(manifest.readinessCases.length).toBeGreaterThan(0);
      expect(manifest.executionCases.length).toBeGreaterThan(0);
    }
  });

  for (const directory of profileDirectories) {
    const profileDirectory = resolve(fixtureRoot, directory);
    const manifestPath = resolve(profileDirectory, "manifest.json");
    const manifest = readJson(manifestPath) as FixtureManifest;
    const profile = parseToolProfileV1(
      readFileSync(resolve(dirname(manifestPath), manifest.profile), "utf8"),
    );

    describe(directory, () => {
      for (const fixture of manifest.versionCases) {
        it(`extracts version: ${fixture.name}`, () => {
          const output = readFileSync(
            fixturePath(profileDirectory, fixture.fixture),
            "utf8",
          );
          expect(
            extractProfileProviderVersion(
              profile,
              versionProbe(profile, output, fixture.exitCode),
            ),
          ).toEqual(fixture.expected);
        });
      }

      for (const fixture of manifest.readinessCases) {
        it(`evaluates readiness: ${fixture.name}`, () => {
          const input = readJson(
            fixturePath(profileDirectory, fixture.fixture),
          ) as NonNullable<typeof fixture.input>;
          const versionOutput = readFileSync(
            fixturePath(profileDirectory, input.versionFixture),
            "utf8",
          );
          expect(
            interpretProfileReadiness(profile, {
              versionProbe: versionProbe(
                profile,
                versionOutput,
                input.versionExitCode,
              ),
              commandExitCodes: input.commandExitCodes,
              configFiles: input.configFiles,
              environment: input.environment,
            }),
          ).toEqual(fixture.expected);
        });
      }

      for (const fixture of manifest.executionCases) {
        it(`interprets execution: ${fixture.name}`, () => {
          const context: ProfileExecutionContext = {
            prompt: "fixture prompt",
            workingDirectory: "/workspace/repo",
            home: "/home/tester",
            workerStateDirectory: "/home/tester/.conclave/worker",
            assignmentTimeoutMs: 30_000,
            executionPolicy: "restricted",
            sessionPolicy: fixture.sessionPolicy,
            ...(fixture.sessionId ? { sessionId: fixture.sessionId } : {}),
          };
          const stdout = readFileSync(
            fixturePath(profileDirectory, fixture.fixture),
            "utf8",
          );
          expect(
            interpretProfileExecution(profile, {
              context,
              stdout,
              stderr: "",
              exitCode: fixture.exitCode ?? 0,
            }),
          ).toEqual(fixture.expected);
        });
      }
    });
  }
});
