import { z } from "zod";

const nonEmptyStr = z.string().trim().min(1);
const semverRegex = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;

export const PluginOperatingSystemSchema = z.enum([
  "macos",
  "linux",
  "windows",
]);
export type PluginOperatingSystem = z.infer<typeof PluginOperatingSystemSchema>;
export type WorkerPluginOperatingSystem = PluginOperatingSystem;

export const PluginArchitectureSchema = z.enum(["arm64", "x64"]);
export type PluginArchitecture = z.infer<typeof PluginArchitectureSchema>;
export type WorkerPluginArchitecture = PluginArchitecture;

export const PluginBillingModeSchema = z.enum([
  "api_metered",
  "subscription",
  "local_compute",
  "external",
  "manual",
  "free",
]);
export type PluginBillingMode = z.infer<typeof PluginBillingModeSchema>;
export type WorkerPluginBillingMode = PluginBillingMode;

export const PluginReleaseChannelSchema = z.enum([
  "stable",
  "beta",
  "development",
]);
export type PluginReleaseChannel = z.infer<typeof PluginReleaseChannelSchema>;
export type WorkerPluginReleaseChannel = PluginReleaseChannel;

export const WorkerPluginManifestSchema = z
  .object({
    pluginId: nonEmptyStr.regex(/^[a-z0-9][a-z0-9-_.]*$/, {
      message:
        "pluginId must be alphanumeric and may contain hyphens, dots, or underscores",
    }),
    version: nonEmptyStr.regex(semverRegex, {
      message: "version must follow semantic versioning (e.g. 1.0.0)",
    }),
    displayName: nonEmptyStr,
    description: z.string().default(""),
    publisher: nonEmptyStr,

    channel: PluginReleaseChannelSchema.default("stable"),

    protocolVersion: nonEmptyStr.default("2.0"),
    minimumAgentVersion: nonEmptyStr
      .regex(semverRegex, {
        message: "minimumAgentVersion must follow semantic versioning",
      })
      .default("0.2.0"),

    supportedOS: z
      .array(PluginOperatingSystemSchema)
      .min(1, "At least one supported OS is required"),
    supportedArchitecture: z
      .array(PluginArchitectureSchema)
      .min(1, "At least one supported architecture is required"),

    roles: z.array(nonEmptyStr).min(1, "At least one role is required"),
    capabilities: z
      .array(nonEmptyStr)
      .min(1, "At least one capability is required"),
    permissions: z.array(nonEmptyStr).default([]),

    configurationSchema: z.record(z.string(), z.unknown()).default({}),
    secretSchema: z.record(z.string(), z.unknown()).default({}),

    entrypoint: nonEmptyStr,
    billingModes: z
      .array(PluginBillingModeSchema)
      .min(1, "At least one billing mode is required"),

    digest: nonEmptyStr,
    signature: z.string().optional(),
  })
  .strict();

export type WorkerPluginManifest = z.infer<typeof WorkerPluginManifestSchema>;

/**
 * Validates a raw object as a valid WorkerPluginManifest.
 */
export function validateWorkerPluginManifest(
  input: unknown,
): WorkerPluginManifest {
  return WorkerPluginManifestSchema.parse(input);
}

export function parseSemver(version: string): {
  major: number;
  minor: number;
  patch: number;
  prerelease?: string;
} | null {
  const match = version
    .trim()
    .match(/^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?/);
  if (!match || !match[1] || !match[2] || !match[3]) return null;
  return {
    major: parseInt(match[1], 10),
    minor: parseInt(match[2], 10),
    patch: parseInt(match[3], 10),
    prerelease: match[4],
  };
}

export function compareSemver(v1: string, v2: string): number {
  const p1 = parseSemver(v1);
  const p2 = parseSemver(v2);
  if (!p1 || !p2) return v1.localeCompare(v2);
  if (p1.major !== p2.major) return p1.major - p2.major;
  if (p1.minor !== p2.minor) return p1.minor - p2.minor;
  if (p1.patch !== p2.patch) return p1.patch - p2.patch;
  if (!p1.prerelease && p2.prerelease) return 1;
  if (p1.prerelease && !p2.prerelease) return -1;
  return 0;
}

/**
 * Checks if a version satisfies a semver range or policy expression (e.g. '^1.4', '~1.4.0', '>=1.0.0', 'latest', '*').
 */
export function satisfiesSemverRange(version: string, range: string): boolean {
  const trimmedRange = range.trim();
  if (
    trimmedRange === "*" ||
    trimmedRange === "latest" ||
    trimmedRange === "" ||
    trimmedRange === "all"
  ) {
    return true;
  }

  const v = parseSemver(version);
  if (!v) return false;

  if (trimmedRange.startsWith("^")) {
    const rawTarget = trimmedRange.slice(1).trim();
    const normalizedTarget =
      rawTarget.split(".").length === 2 ? `${rawTarget}.0` : rawTarget;
    const target = parseSemver(normalizedTarget);
    if (!target) return false;

    if (compareSemver(version, normalizedTarget) < 0) return false;

    if (target.major > 0) {
      return v.major === target.major;
    }
    if (target.minor > 0) {
      return v.major === 0 && v.minor === target.minor;
    }
    return v.major === 0 && v.minor === 0 && v.patch === target.patch;
  }

  if (trimmedRange.startsWith("~")) {
    const rawTarget = trimmedRange.slice(1).trim();
    const normalizedTarget =
      rawTarget.split(".").length === 2 ? `${rawTarget}.0` : rawTarget;
    const target = parseSemver(normalizedTarget);
    if (!target) return false;

    if (compareSemver(version, normalizedTarget) < 0) return false;
    return v.major === target.major && v.minor === target.minor;
  }

  if (trimmedRange.startsWith(">=")) {
    return compareSemver(version, trimmedRange.slice(2).trim()) >= 0;
  }
  if (trimmedRange.startsWith("<=")) {
    return compareSemver(version, trimmedRange.slice(2).trim()) <= 0;
  }
  if (trimmedRange.startsWith(">")) {
    return compareSemver(version, trimmedRange.slice(1).trim()) > 0;
  }
  if (trimmedRange.startsWith("<")) {
    return compareSemver(version, trimmedRange.slice(1).trim()) < 0;
  }

  return compareSemver(version, trimmedRange) === 0;
}

export interface AgentHostCompatibilityCheck {
  readonly os: string;
  readonly architecture: string;
  readonly agentVersion: string;
}

export interface CompatibilityCheckResult {
  readonly compatible: boolean;
  readonly reason?: string;
}

export function isPluginCompatibleWithAgent(
  manifest: WorkerPluginManifest,
  agent: AgentHostCompatibilityCheck,
): CompatibilityCheckResult {
  if (!manifest.supportedOS.includes(agent.os as PluginOperatingSystem)) {
    return {
      compatible: false,
      reason: `Host OS '${agent.os}' is not supported by plugin (supported: ${manifest.supportedOS.join(", ")})`,
    };
  }
  if (
    !manifest.supportedArchitecture.includes(
      agent.architecture as PluginArchitecture,
    )
  ) {
    return {
      compatible: false,
      reason: `Host architecture '${agent.architecture}' is not supported by plugin (supported: ${manifest.supportedArchitecture.join(", ")})`,
    };
  }
  if (compareSemver(agent.agentVersion, manifest.minimumAgentVersion) < 0) {
    return {
      compatible: false,
      reason: `Agent version '${agent.agentVersion}' is below minimum required version '${manifest.minimumAgentVersion}'`,
    };
  }
  return { compatible: true };
}
