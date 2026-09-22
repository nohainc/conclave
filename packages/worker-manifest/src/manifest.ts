import { z } from "zod";

const nonEmptyStr = z.string().trim().min(1);
const semverRegex = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;

export const WorkerOperatingSystemSchema = z.enum([
  "macos",
  "linux",
  "windows",
]);
export type WorkerOperatingSystem = z.infer<typeof WorkerOperatingSystemSchema>;

export const WorkerArchitectureSchema = z.enum(["arm64", "x64"]);
export type WorkerArchitecture = z.infer<typeof WorkerArchitectureSchema>;

export const WorkerBillingModeSchema = z.enum([
  "api_metered",
  "subscription",
  "local_compute",
  "external",
  "manual",
  "free",
]);
export type WorkerBillingMode = z.infer<typeof WorkerBillingModeSchema>;

export const WorkerReleaseChannelSchema = z.enum([
  "stable",
  "beta",
  "development",
]);
export type WorkerReleaseChannel = z.infer<typeof WorkerReleaseChannelSchema>;

export const WorkerSessionModeSchema = z.enum([
  "stateless",
  "isolated_workspace",
  "reuse_session",
  "persistent_context",
]);
export type WorkerSessionMode = z.infer<typeof WorkerSessionModeSchema>;

export const WorkerCredentialAuthModeSchema = z.enum([
  "none",
  "api_key",
  "oauth_browser",
  "local_cli_session",
  "interactive_custom",
]);
export type WorkerCredentialAuthMode = z.infer<
  typeof WorkerCredentialAuthModeSchema
>;

export const WorkerCredentialSharingPolicySchema = z.enum([
  "private_only",
  "owner_controlled",
  "workspace_capable",
]);
export type WorkerCredentialSharingPolicy = z.infer<
  typeof WorkerCredentialSharingPolicySchema
>;

export const WorkerCredentialRequirementSchema = z
  .object({
    name: z.string().optional(),
    authMode: WorkerCredentialAuthModeSchema,
    sharingPolicy:
      WorkerCredentialSharingPolicySchema.default("owner_controlled"),
    required: z.boolean().default(true),
    envVar: z.string().optional(),
    description: z.string().optional(),
    fields: z.record(z.string(), z.unknown()).optional(),
  })
  .strict();
export type WorkerCredentialRequirement = z.infer<
  typeof WorkerCredentialRequirementSchema
>;

export const WorkerConcurrencyModelSchema = z
  .object({
    maxConcurrentAssignments: z.number().int().min(1).default(1),
    persistentRuntime: z.boolean().default(false),
    isolation: z.enum(["process", "thread", "shared"]).default("process"),
  })
  .strict();
export type WorkerConcurrencyModel = z.infer<
  typeof WorkerConcurrencyModelSchema
>;

export const WorkerManifestSchema = z
  .object({
    workerId: nonEmptyStr.regex(/^[a-z0-9][a-z0-9-_.]*$/, {
      message:
        "workerId must be alphanumeric and may contain hyphens, dots, or underscores",
    }),
    version: nonEmptyStr.regex(semverRegex, {
      message: "version must follow semantic versioning (e.g. 1.0.0)",
    }),
    displayName: nonEmptyStr,
    description: z.string().default(""),
    publisher: nonEmptyStr,

    channel: WorkerReleaseChannelSchema.default("stable"),

    protocolVersion: nonEmptyStr.default("4.0"),
    minimumHostVersion: nonEmptyStr
      .regex(semverRegex, {
        message: "minimumHostVersion must follow semantic versioning",
      })
      .default("0.1.0"),

    supportedOS: z
      .array(WorkerOperatingSystemSchema)
      .min(1, "At least one supported OS is required"),
    supportedArchitecture: z
      .array(WorkerArchitectureSchema)
      .min(1, "At least one supported architecture is required"),

    roles: z.array(nonEmptyStr).min(1, "At least one role is required"),
    capabilities: z
      .array(nonEmptyStr)
      .min(1, "At least one capability is required"),
    permissions: z.array(nonEmptyStr).default([]),

    credentialRequirements: z
      .array(WorkerCredentialRequirementSchema)
      .default([]),
    credentialSharingPolicy:
      WorkerCredentialSharingPolicySchema.default("owner_controlled"),

    configurationSchema: z.record(z.string(), z.unknown()).default({}),
    secretSchema: z.record(z.string(), z.unknown()).optional(),

    sessionModes: z
      .array(WorkerSessionModeSchema)
      .min(1, "At least one session mode is required")
      .default(["stateless"]),

    concurrencyModel: WorkerConcurrencyModelSchema.default({
      maxConcurrentAssignments: 1,
      persistentRuntime: false,
      isolation: "process",
    }),

    entrypoint: nonEmptyStr,
    billingModes: z
      .array(WorkerBillingModeSchema)
      .min(1, "At least one billing mode is required")
      .default(["free"]),

    digest: nonEmptyStr,
    signature: z.string().optional(),
  })
  .strict();

export type WorkerManifest = z.infer<typeof WorkerManifestSchema>;

const LEGACY_ID_KEY = "plugin" + "Id";
const LEGACY_AGENT_VER_KEY = "minimum" + "AgentVersion";

/**
 * Normalizes input object to translate legacy/alternate fields before validation.
 */
function normalizeManifestInput(raw: unknown): unknown {
  if (typeof raw !== "object" || raw === null) return raw;
  const input = { ...(raw as Record<string, unknown>) };

  // Map legacy plugin id -> workerId
  if (!input.workerId && input[LEGACY_ID_KEY]) {
    input.workerId = input[LEGACY_ID_KEY];
  }
  delete input[LEGACY_ID_KEY];

  // Map legacy minimum agent version -> minimumHostVersion
  if (!input.minimumHostVersion && input[LEGACY_AGENT_VER_KEY]) {
    input.minimumHostVersion = input[LEGACY_AGENT_VER_KEY];
  }
  delete input[LEGACY_AGENT_VER_KEY];

  // Map sharingPolicy -> credentialSharingPolicy
  if (!input.credentialSharingPolicy && input.sharingPolicy) {
    input.credentialSharingPolicy = input.sharingPolicy;
  }

  // Map concurrency -> concurrencyModel
  if (!input.concurrencyModel && input.concurrency) {
    input.concurrencyModel = input.concurrency;
  }

  // Normalize credential requirements authMode
  if (Array.isArray(input.credentialRequirements)) {
    input.credentialRequirements = input.credentialRequirements.map((req) => {
      if (typeof req === "object" && req !== null) {
        const reqObj = { ...(req as Record<string, unknown>) };
        if (reqObj.authMode === "interactive/custom") {
          reqObj.authMode = "interactive_custom";
        }
        return reqObj;
      }
      return req;
    });
  }

  return input;
}

/**
 * Validates credential requirements against policy constraints.
 */
function validateCredentialRequirementsPolicy(manifest: WorkerManifest): void {
  // If manifest has private_only sharing policy, no credential requirement can declare workspace_capable
  if (manifest.credentialSharingPolicy === "private_only") {
    for (const req of manifest.credentialRequirements) {
      if (req.sharingPolicy === "workspace_capable") {
        throw new Error(
          `Credential requirement '${req.name ?? req.authMode}' specifies 'workspace_capable' sharing policy, which violates manifest 'private_only' policy`,
        );
      }
    }
  }

  // Check if secretSchema is provided with required keys but credentialRequirements are empty with authMode 'none'
  if (
    manifest.secretSchema &&
    Object.keys(manifest.secretSchema).length > 0 &&
    manifest.credentialRequirements.length === 1 &&
    manifest.credentialRequirements[0]?.authMode === "none"
  ) {
    throw new Error(
      "Worker declares secretSchema but credential requirement is set to 'none'",
    );
  }
}

/**
 * Validates a raw object as a valid WorkerManifest.
 */
export function validateWorkerManifest(input: unknown): WorkerManifest {
  const normalized = normalizeManifestInput(input);
  const manifest = WorkerManifestSchema.parse(normalized);
  validateCredentialRequirementsPolicy(manifest);
  return manifest;
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

export interface HostCompatibilityCheck {
  readonly os: string;
  readonly architecture: string;
  readonly hostVersion: string;
}

export interface CompatibilityCheckResult {
  readonly compatible: boolean;
  readonly reason?: string;
}

export function isWorkerCompatibleWithHost(
  manifest: WorkerManifest,
  host: HostCompatibilityCheck,
): CompatibilityCheckResult {
  if (!manifest.supportedOS.includes(host.os as WorkerOperatingSystem)) {
    return {
      compatible: false,
      reason: `Host OS '${host.os}' is not supported by worker (supported: ${manifest.supportedOS.join(", ")})`,
    };
  }
  if (
    !manifest.supportedArchitecture.includes(
      host.architecture as WorkerArchitecture,
    )
  ) {
    return {
      compatible: false,
      reason: `Host architecture '${host.architecture}' is not supported by worker (supported: ${manifest.supportedArchitecture.join(", ")})`,
    };
  }
  const minVersion = manifest.minimumHostVersion;
  if (compareSemver(host.hostVersion, minVersion) < 0) {
    return {
      compatible: false,
      reason: `Host version '${host.hostVersion}' is below minimum required version '${minVersion}'`,
    };
  }
  return { compatible: true };
}

// Deprecated alias for backwards compatibility
export type AgentHostCompatibilityCheck = {
  readonly os: string;
  readonly architecture: string;
  readonly agentVersion: string;
};

export function isPluginCompatibleWithAgent(
  manifest: WorkerManifest,
  agent: AgentHostCompatibilityCheck,
): CompatibilityCheckResult {
  return isWorkerCompatibleWithHost(manifest, {
    os: agent.os,
    architecture: agent.architecture,
    hostVersion: agent.agentVersion,
  });
}
