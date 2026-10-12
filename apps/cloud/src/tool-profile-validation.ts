import {
  validateToolProfileV1,
  type ToolProfileV1,
} from "@conclave/tool-profile";
import { canonicalReleaseJson } from "./release-trust.js";

export class ToolProfileRegistryError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "ToolProfileRegistryError";
  }
}

export function validateProviderCompatibilityForPublication(
  profile: ToolProfileV1,
): void {
  try {
    validateToolProfileV1(profile, {
      requireProviderCompatibility: true,
      rejectPlaceholderProviderRange: true,
    });
  } catch (error) {
    throw new ToolProfileRegistryError(
      409,
      error instanceof Error
        ? error.message
        : "Provider compatibility is invalid",
    );
  }
}

export interface ToolProfileRegistryEnvironment {
  readonly CONCLAVE_DB: D1Database;
  readonly CONCLAVE_RELEASE_TRUST_KEYS_JSON?: string;
  readonly CONCLAVE_RELEASE_PUBLISHER?: string;
  readonly CONCLAVE_RELEASE_PRIVATE_KEY?: string;
  readonly CONCLAVE_RELEASE_SIGNING_KEY_ID?: string;
}

export interface WorkerProfilePublicationEvidence {
  readonly formatVersion: 1;
  readonly workerTypeId: string;
  readonly candidateDigest: string;
  readonly engineVersion: string;
  readonly providerToolName: string;
  readonly providerToolVersion: string;
  readonly testedAt: string;
  readonly scenarios: Readonly<Record<string, "passed" | "not_applicable">>;
}

const acceptanceScenarios = [
  "passive_probe",
  "live_probe",
  "model_selection",
  "representative_thread_write",
  "durable_session_start",
  "durable_session_resume",
  "cancellation",
  "timeout",
] as const;

function compareReleaseSemver(left: string, right: string): number {
  const parse = (value: string) => {
    const match =
      /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/.exec(
        value,
      );
    if (!match) return null;
    return {
      core: match.slice(1, 4).map(Number),
      prerelease: match[4]?.split(".") ?? null,
    };
  };
  const a = parse(left);
  const b = parse(right);
  if (!a || !b) return Number.NaN;
  for (let index = 0; index < 3; index++)
    if (a.core[index] !== b.core[index])
      return a.core[index]! < b.core[index]! ? -1 : 1;
  if (a.prerelease === null || b.prerelease === null)
    return a.prerelease === b.prerelease ? 0 : a.prerelease === null ? 1 : -1;
  const length = Math.max(a.prerelease.length, b.prerelease.length);
  for (let index = 0; index < length; index++) {
    const leftPart = a.prerelease[index];
    const rightPart = b.prerelease[index];
    if (leftPart === undefined || rightPart === undefined)
      return leftPart === rightPart ? 0 : leftPart === undefined ? -1 : 1;
    if (leftPart === rightPart) continue;
    const leftNumeric = /^(0|[1-9]\d*)$/.test(leftPart);
    const rightNumeric = /^(0|[1-9]\d*)$/.test(rightPart);
    if (leftNumeric && rightNumeric)
      return Number(leftPart) < Number(rightPart) ? -1 : 1;
    if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1;
    return leftPart < rightPart ? -1 : 1;
  }
  return 0;
}

function profileRangeIncludes(
  version: string,
  ranges: readonly { min: string; maxExclusive: string }[],
): boolean {
  return ranges.some((range) => {
    const lower = compareReleaseSemver(version, range.min);
    const upper = compareReleaseSemver(version, range.maxExclusive);
    return (
      Number.isFinite(lower) &&
      Number.isFinite(upper) &&
      lower >= 0 &&
      upper < 0
    );
  });
}

export function toolProfileAcceptanceScenarioStatuses(
  profile: ToolProfileV1,
): Readonly<Record<string, "passed" | "not_applicable">> {
  const durable = profile.session.supported;
  return {
    passive_probe: "passed",
    live_probe: "passed",
    model_selection:
      profile.model.supported && (profile.model.allowlist?.length ?? 0) > 0
        ? "passed"
        : "not_applicable",
    representative_thread_write:
      profile.sandbox.mappings.restricted.length > 0
        ? "passed"
        : "not_applicable",
    durable_session_start: durable ? "passed" : "not_applicable",
    durable_session_resume: durable ? "passed" : "not_applicable",
    cancellation: "passed",
    timeout: "passed",
  };
}

export function validateWorkerProfilePublicationEvidence(
  input: unknown,
  expected: {
    workerTypeId: string;
    candidateDigest: string;
    profile: ToolProfileV1;
  },
): WorkerProfilePublicationEvidence {
  const fail = (): never => {
    throw new ToolProfileRegistryError(
      409,
      "Publication requires complete, recent evidence for this exact Profile candidate",
    );
  };
  if (!input || typeof input !== "object" || Array.isArray(input))
    return fail();
  const evidence = input as Record<string, unknown>;
  const forbiddenKeys = new Set([
    "secrets",
    "env",
    "environment",
    "stdout",
    "stderr",
    "apiKey",
    "apiKeys",
    "token",
    "tokens",
    "credentials",
  ]);
  if (Object.keys(evidence).some((key) => forbiddenKeys.has(key)))
    throw new ToolProfileRegistryError(
      400,
      "Raw provider secrets, environment dumps, or unrestricted stdout/stderr are forbidden in Cloud evidence",
    );
  const allowedKeys = new Set([
    "formatVersion",
    "workerTypeId",
    "candidateDigest",
    "engineVersion",
    "providerToolName",
    "providerToolVersion",
    "testedAt",
    "scenarios",
  ]);
  if (Object.keys(evidence).some((key) => !allowedKeys.has(key))) return fail();
  const testedAt =
    typeof evidence.testedAt === "string"
      ? Date.parse(evidence.testedAt)
      : Number.NaN;
  if (
    evidence.formatVersion !== 1 ||
    evidence.workerTypeId !== expected.workerTypeId ||
    evidence.candidateDigest !== expected.candidateDigest ||
    typeof evidence.engineVersion !== "string" ||
    !profileRangeIncludes(evidence.engineVersion, [
      expected.profile.engineCompatibility,
    ]) ||
    evidence.providerToolName !== expected.profile.providerTool.name ||
    typeof evidence.providerToolVersion !== "string" ||
    !profileRangeIncludes(
      evidence.providerToolVersion,
      expected.profile.providerTool.supportedVersions,
    ) ||
    !Number.isFinite(testedAt) ||
    testedAt > Date.now() + 5 * 60 * 1000 ||
    Date.now() - testedAt > 90 * 24 * 60 * 60 * 1000 ||
    !evidence.scenarios ||
    typeof evidence.scenarios !== "object" ||
    Array.isArray(evidence.scenarios)
  )
    return fail();
  const scenarios = evidence.scenarios as Record<string, unknown>;
  const expectedStatuses = toolProfileAcceptanceScenarioStatuses(
    expected.profile,
  );
  if (
    Object.keys(scenarios).length !== acceptanceScenarios.length ||
    acceptanceScenarios.some(
      (name) => scenarios[name] !== expectedStatuses[name],
    )
  )
    return fail();
  if (new TextEncoder().encode(JSON.stringify(evidence)).byteLength > 32768)
    return fail();
  return evidence as unknown as WorkerProfilePublicationEvidence;
}

export function validateId(value: string, label: string): void {
  if (!/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(value) || value.length > 96)
    throw new ToolProfileRegistryError(400, label + " is invalid");
}

export function parseProfile(
  input: unknown,
  _compatibilityIdentity?: unknown,
): { profile: ToolProfileV1; payload: string } {
  let profile: ToolProfileV1;
  try {
    profile = validateToolProfileV1(input);
  } catch (error) {
    throw new ToolProfileRegistryError(
      400,
      error instanceof Error ? error.message : "Tool Profile v1 is invalid",
    );
  }
  const payload = canonicalReleaseJson(profile);
  if (new TextEncoder().encode(payload).byteLength > 256 * 1024)
    throw new ToolProfileRegistryError(
      400,
      "Tool Profile payload exceeds the Profile limit",
    );
  return { profile, payload };
}

export async function profileDigest(canonicalPayload: string): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(canonicalPayload),
    ),
  );
  return [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function workerProfileSigningMessage(args: {
  publisher: string;
  signingKeyId: string;
  workerTypeId: string;
  revision: number;
  schemaVersion: number;
  payloadDigest: string;
}): string {
  return `conclave-worker-profile-v9\\n${canonicalReleaseJson({ domain: "conclave-worker-profile-v9", publisher: args.publisher, signingKeyId: args.signingKeyId, workerTypeId: args.workerTypeId, revision: args.revision, schemaVersion: args.schemaVersion, payloadDigest: args.payloadDigest })}`;
}
