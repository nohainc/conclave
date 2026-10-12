import {
  compareSemver,
  parseToolProfileV1,
  type ToolProfileV1,
} from "@conclave/tool-profile";
import { canonicalReleaseJson } from "./release-trust.js";

export type ToolProfileChannel = "testing" | "beta" | "stable";
export type ToolProfileLifecycle =
  "draft" | "testing" | "beta" | "stable" | "retired" | "revoked";

export class ToolProfileRegistryError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "ToolProfileRegistryError";
  }
}

/** Publication requires an explicitly bounded provider compatibility claim. */
export function validateProviderCompatibilityForPublication(
  profile: ToolProfileV1,
): void {
  const ranges = profile.providerTool.supportedVersions;
  if (ranges.length === 0) {
    throw new ToolProfileRegistryError(
      409,
      "Provider compatibility must be configured before publication",
    );
  }
  if (
    ranges.some(
      (range) =>
        compareSemver(range.min, "1.0.0") <= 0 &&
        compareSemver(range.maxExclusive, "50.0.0") >= 0,
    )
  ) {
    throw new ToolProfileRegistryError(
      409,
      "Provider compatibility contains an unsupported placeholder range",
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

export interface ToolProfileDefinitionInput {
  readonly profileDefinitionId: string;
  readonly workerTypeId: string;
  readonly displayName: string;
  readonly providerToolName: string;
  readonly actorUserId: string;
}

export interface ApprovedLogicalWorkerInput extends ToolProfileDefinitionInput {
  readonly description: string;
  readonly releaseStage: ToolProfileChannel;
  readonly sortOrder: number;
}

export interface ToolProfileReleaseIdentity {
  readonly profileDefinitionId: string;
  readonly releaseVersion: number;
}

export interface ToolProfileAcceptanceEvidence {
  readonly formatVersion: 2;
  readonly profileDefinitionId: string;
  readonly releaseVersion: number;
  readonly profileReleaseVersion: string;
  readonly profileDigest: string;
  readonly logicalWorkerTypeId: string;
  readonly engineVersion: string;
  readonly providerToolName: string;
  readonly providerToolVersion: string;
  readonly acceptedAt: string;
  readonly scenarios: Readonly<Record<string, "passed" | "not_applicable">>;
}

/**
 * V9 publication evidence identifies the exact candidate and compatibility
 * matrix entry tested by Profile Lab. It is evidence of a client-side test,
 * not cryptographic proof that Cloud executed the test.
 */
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

export const channelNames = new Set<ToolProfileChannel>([
  "testing",
  "beta",
  "stable",
]);
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

export type ToolProfileAcceptanceScenario =
  (typeof acceptanceScenarios)[number];
export type ToolProfileAcceptanceScenarioStatus = "passed" | "not_applicable";

/**
 * Returns the exact scenario statuses expected for a Tool Profile. Cloud and
 * Profile Lab retain all eight scenario keys; unsupported execution scenarios
 * are explicitly recorded as not_applicable rather than omitted or passed.
 */
export function toolProfileAcceptanceScenarioStatuses(
  profile: ToolProfileV1,
): Readonly<
  Record<ToolProfileAcceptanceScenario, ToolProfileAcceptanceScenarioStatus>
> {
  // Session support is declared by the session contract itself. The former
  // Profile capability list is legacy metadata and is not required for
  // qualification or execution admission.
  const supportsDurableSession = profile.session.supported;
  const statuses: Record<
    ToolProfileAcceptanceScenario,
    ToolProfileAcceptanceScenarioStatus
  > = {
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
    durable_session_start: supportsDurableSession ? "passed" : "not_applicable",
    durable_session_resume: supportsDurableSession
      ? "passed"
      : "not_applicable",
    cancellation: "passed",
    timeout: "passed",
  };
  return statuses;
}

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
  for (let index = 0; index < 3; index++) {
    if (a.core[index] !== b.core[index])
      return a.core[index]! < b.core[index]! ? -1 : 1;
  }
  if (a.prerelease === null || b.prerelease === null) {
    if (a.prerelease === b.prerelease) return 0;
    return a.prerelease === null ? 1 : -1;
  }
  const length = Math.max(a.prerelease.length, b.prerelease.length);
  for (let index = 0; index < length; index++) {
    const leftPart = a.prerelease[index];
    const rightPart = b.prerelease[index];
    if (leftPart === undefined || rightPart === undefined) {
      if (leftPart === rightPart) return 0;
      return leftPart === undefined ? -1 : 1;
    }
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

function releaseRangeIncludes(
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

export function validateToolProfileAcceptanceEvidence(
  input: unknown,
  expected: {
    identity: ToolProfileReleaseIdentity;
    payloadDigest: string;
    profile: ToolProfileV1;
  },
  purpose: "acceptance" | "local qualification" = "acceptance",
): ToolProfileAcceptanceEvidence {
  const fail = (): never => {
    throw new ToolProfileRegistryError(
      409,
      purpose === "acceptance"
        ? "Stable promotion requires complete real Profile acceptance evidence"
        : "Draft publication requires a complete local execution qualification",
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
  if (Object.keys(evidence).some((key) => forbiddenKeys.has(key))) {
    throw new ToolProfileRegistryError(
      400,
      "Raw provider secrets, environment dumps, or unrestricted stdout/stderr are forbidden in Cloud evidence",
    );
  }
  const allowedKeys = new Set([
    "formatVersion",
    "profileDefinitionId",
    "releaseVersion",
    "profileReleaseVersion",
    "logicalWorkerTypeId",
    "profileDigest",
    "engineVersion",
    "providerToolName",
    "providerToolVersion",
    "acceptedAt",
    "scenarios",
  ]);
  if (Object.keys(evidence).some((key) => !allowedKeys.has(key))) return fail();
  if (
    evidence.formatVersion !== 2 ||
    evidence.profileDefinitionId !== expected.identity.profileDefinitionId ||
    evidence.releaseVersion !== expected.identity.releaseVersion ||
    evidence.profileReleaseVersion !==
      String(expected.identity.releaseVersion) ||
    evidence.logicalWorkerTypeId !== expected.profile.logicalWorkerTypeId ||
    evidence.profileDigest !== expected.payloadDigest ||
    evidence.providerToolName !== expected.profile.providerTool.name ||
    typeof evidence.engineVersion !== "string" ||
    !releaseRangeIncludes(evidence.engineVersion, [
      expected.profile.engineCompatibility,
    ]) ||
    typeof evidence.providerToolVersion !== "string" ||
    !releaseRangeIncludes(
      evidence.providerToolVersion,
      expected.profile.providerTool.supportedVersions,
    ) ||
    typeof evidence.acceptedAt !== "string" ||
    !Number.isFinite(Date.parse(evidence.acceptedAt)) ||
    Date.parse(evidence.acceptedAt) > Date.now() + 5 * 60 * 1000 ||
    Date.now() - Date.parse(evidence.acceptedAt) > 90 * 24 * 60 * 60 * 1000 ||
    !evidence.scenarios ||
    typeof evidence.scenarios !== "object" ||
    Array.isArray(evidence.scenarios)
  ) {
    return fail();
  }
  let expectedScenarioStatuses: ReturnType<
    typeof toolProfileAcceptanceScenarioStatuses
  >;
  try {
    expectedScenarioStatuses = toolProfileAcceptanceScenarioStatuses(
      expected.profile,
    );
  } catch {
    return fail();
  }
  const scenarios = evidence.scenarios as Record<string, unknown>;
  if (
    Object.keys(scenarios).length !== acceptanceScenarios.length ||
    acceptanceScenarios.some(
      (name) => scenarios[name] !== expectedScenarioStatuses[name],
    )
  ) {
    return fail();
  }
  if (new TextEncoder().encode(JSON.stringify(evidence)).byteLength > 32768)
    return fail();
  return evidence as unknown as ToolProfileAcceptanceEvidence;
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
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    return fail();
  }
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
  if (Object.keys(evidence).some((key) => forbiddenKeys.has(key))) {
    throw new ToolProfileRegistryError(
      400,
      "Raw provider secrets, environment dumps, or unrestricted stdout/stderr are forbidden in Cloud evidence",
    );
  }
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
  if (
    evidence.formatVersion !== 1 ||
    evidence.workerTypeId !== expected.workerTypeId ||
    evidence.candidateDigest !== expected.candidateDigest ||
    typeof evidence.engineVersion !== "string" ||
    !releaseRangeIncludes(evidence.engineVersion, [
      expected.profile.engineCompatibility,
    ]) ||
    evidence.providerToolName !== expected.profile.providerTool.name ||
    typeof evidence.providerToolVersion !== "string" ||
    !releaseRangeIncludes(
      evidence.providerToolVersion,
      expected.profile.providerTool.supportedVersions,
    ) ||
    typeof evidence.testedAt !== "string" ||
    !Number.isFinite(Date.parse(evidence.testedAt)) ||
    Date.parse(evidence.testedAt) > Date.now() + 5 * 60 * 1000 ||
    Date.now() - Date.parse(evidence.testedAt) > 90 * 24 * 60 * 60 * 1000 ||
    !evidence.scenarios ||
    typeof evidence.scenarios !== "object" ||
    Array.isArray(evidence.scenarios)
  ) {
    return fail();
  }
  const expectedScenarioStatuses = toolProfileAcceptanceScenarioStatuses(
    expected.profile,
  );
  const scenarios = evidence.scenarios as Record<string, unknown>;
  if (
    Object.keys(scenarios).length !== acceptanceScenarios.length ||
    acceptanceScenarios.some(
      (name) => scenarios[name] !== expectedScenarioStatuses[name],
    )
  ) {
    return fail();
  }
  if (new TextEncoder().encode(JSON.stringify(evidence)).byteLength > 32768) {
    return fail();
  }
  return evidence as unknown as WorkerProfilePublicationEvidence;
}

export function validateId(value: string, label: string): void {
  if (!/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(value) || value.length > 96) {
    throw new ToolProfileRegistryError(400, `${label} is invalid`);
  }
}

export function validateVersion(value: number): void {
  if (!Number.isInteger(value) || value < 1 || value > 2_147_483_647) {
    throw new ToolProfileRegistryError(400, "releaseVersion is invalid");
  }
}

export function parseProfile(
  input: unknown,
  identity?: ToolProfileReleaseIdentity,
): {
  profile: ToolProfileV1;
  payload: string;
} {
  let profile: ToolProfileV1;
  try {
    profile = parseToolProfileV1(input);
  } catch {
    throw new ToolProfileRegistryError(400, "Tool Profile v1 is invalid");
  }
  rejectPlaintextCredentialMaterial(profile);
  if (
    identity &&
    (profile.profileDefinitionId !== identity.profileDefinitionId ||
      profile.releaseVersion !== identity.releaseVersion)
  ) {
    throw new ToolProfileRegistryError(
      400,
      "Tool Profile identity does not match the requested release",
    );
  }
  const payload = canonicalReleaseJson(profile);
  if (new TextEncoder().encode(payload).byteLength > 256 * 1024) {
    throw new ToolProfileRegistryError(
      400,
      "Tool Profile payload exceeds the release limit",
    );
  }
  return { profile, payload };
}

export function rejectPlaintextCredentialMaterial(
  profile: ToolProfileV1,
): void {
  const reservedEnvironmentName =
    /^(?:CONCLAVE_|CLOUD_|WORKER_|WORKSPACE_|SECRET_STORE_)/i;
  if (
    profile.environment.passthrough.some((name) =>
      reservedEnvironmentName.test(name),
    ) ||
    Object.keys(profile.environment.set).some((name) =>
      reservedEnvironmentName.test(name),
    )
  ) {
    throw new ToolProfileRegistryError(
      400,
      "Tool Profile releases cannot request reserved environment variable names",
    );
  }
  const secretName =
    /(?:API[_-]?KEY|ACCESS[_-]?TOKEN|PASSWORD|CLIENT[_-]?SECRET|PRIVATE[_-]?KEY|CREDENTIAL)/i;
  if (
    Object.keys(profile.environment.set).some((name) => secretName.test(name))
  ) {
    throw new ToolProfileRegistryError(
      400,
      "Tool Profile releases cannot store credentials in environment values",
    );
  }
  const credentialMaterial =
    /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\bsk-[A-Za-z0-9_-]{20,}\b|\bgh[pousr]_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b|\bAIza[0-9A-Za-z_-]{35}\b|\b(?:api[_-]?key|access[_-]?token|password|client[_-]?secret)\s*[:=]\s*[^\s,;]{8,}/i;
  const visit = (value: unknown): boolean => {
    if (typeof value === "string") return credentialMaterial.test(value);
    if (Array.isArray(value)) return value.some(visit);
    if (value && typeof value === "object") {
      return Object.values(value).some(visit);
    }
    return false;
  };
  if (visit(profile)) {
    throw new ToolProfileRegistryError(
      400,
      "Tool Profile releases cannot contain plaintext credential material",
    );
  }
}

export function validateToolProfileReleasePayload(
  input: unknown,
  identity?: ToolProfileReleaseIdentity,
): ToolProfileV1 {
  return parseProfile(input, identity).profile;
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

/** Canonical Ed25519 message for an immutable Tool Profile Release v1.
 * The digest binds every behavior field; the explicit statement binds the
 * database/API identity and compatibility claims to that exact payload.
 */
export function toolProfileReleaseSigningMessage(args: {
  publisher: string;
  signingKeyId: string;
  payloadDigest: string;
  profile: ToolProfileV1;
}): string {
  const { profile } = args;
  return `conclave-tool-profile-release-v1\n${canonicalReleaseJson({
    domain: "conclave-tool-profile-release-v1",
    publisher: args.publisher,
    signingKeyId: args.signingKeyId,
    payloadDigest: args.payloadDigest,
    profileDefinitionId: profile.profileDefinitionId,
    releaseVersion: profile.releaseVersion,
    logicalWorkerTypeId: profile.logicalWorkerTypeId,
    engineFamily: profile.engineFamily,
    schemaVersion: profile.schemaVersion,
    engineCompatibility: profile.engineCompatibility,
    providerToolName: profile.providerTool.name,
    providerCompatibility: profile.providerTool.supportedVersions,
  })}`;
}

/** Canonical Ed25519 message for the V9 current Worker Profile snapshot. */
export function workerProfileSigningMessage(args: {
  publisher: string;
  signingKeyId: string;
  workerTypeId: string;
  revision: number;
  schemaVersion: number;
  payloadDigest: string;
}): string {
  return `conclave-worker-profile-v9\n${canonicalReleaseJson({
    domain: "conclave-worker-profile-v9",
    publisher: args.publisher,
    signingKeyId: args.signingKeyId,
    workerTypeId: args.workerTypeId,
    revision: args.revision,
    schemaVersion: args.schemaVersion,
    payloadDigest: args.payloadDigest,
  })}`;
}
