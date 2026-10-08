import {
  signEd25519ReleaseMessage,
  verifyEd25519ReleaseSignature,
} from "./release-trust.js";
import {
  parseWorkerDescriptor,
  type WorkerDescriptor,
} from "@conclave/protocol";
import {
  ToolProfileRegistryError,
  channelNames,
  parseProfile,
  profileDigest,
  productCapabilities,
  toolProfileReleaseSigningMessage,
  validateId,
  validateToolProfileAcceptanceEvidence,
  validateProviderCompatibilityForPublication,
  validateVersion,
} from "./tool-profile-validation.js";
import type {
  ApprovedLogicalWorkerInput,
  ToolProfileAcceptanceEvidence,
  ToolProfileChannel,
  ToolProfileDefinitionInput,
  ToolProfileLifecycle,
  ToolProfileRegistryEnvironment,
  ToolProfileReleaseIdentity,
} from "./tool-profile-validation.js";

export {
  ToolProfileRegistryError,
  toolProfileReleaseSigningMessage,
  validateToolProfileAcceptanceEvidence,
  validateProviderCompatibilityForPublication,
  validateToolProfileReleasePayload,
} from "./tool-profile-validation.js";

export interface ToolProfileSigningPreflight {
  readonly ready: boolean;
  readonly publisher?: string;
  readonly signingKeyId?: string;
  readonly issues: readonly (
    | "publisher_missing"
    | "signing_key_id_missing"
    | "private_key_missing"
    | "trust_roots_missing"
    | "signer_trust_mismatch"
    | "signing_key_revoked"
    | "revocation_check_failed"
  )[];
}

// Production databases created before the space/thread cutover can still
// contain the retired workstream capability names. Normalize those persisted
// values at the Cloud boundary so catalog reads remain available while the
// data migration is completed; all downstream contracts use thread names.
const retiredCapabilityAliases: Readonly<Record<string, string>> = {
  workstream_read: "thread_read",
  workstream_write: "thread_write",
};

const signingPreflightMessage =
  "conclave-tool-profile-signing-preflight-v1\nconclave";

/** Confirms Cloud's configured signer is trusted and not revoked. */
export async function toolProfileSigningPreflight(
  env: ToolProfileRegistryEnvironment,
): Promise<ToolProfileSigningPreflight> {
  const publisher = env.CONCLAVE_RELEASE_PUBLISHER?.trim();
  const signingKeyId = env.CONCLAVE_RELEASE_SIGNING_KEY_ID?.trim();
  const privateKey = env.CONCLAVE_RELEASE_PRIVATE_KEY?.trim();
  const trustKeysJson = env.CONCLAVE_RELEASE_TRUST_KEYS_JSON?.trim();
  const issues: ToolProfileSigningPreflight["issues"][number][] = [];

  if (!publisher) issues.push("publisher_missing");
  if (!signingKeyId) issues.push("signing_key_id_missing");
  if (!privateKey) issues.push("private_key_missing");
  if (!trustKeysJson) issues.push("trust_roots_missing");

  if (publisher && signingKeyId && privateKey && trustKeysJson) {
    try {
      const signature = signEd25519ReleaseMessage({
        privateKeyBase64OrPem: privateKey,
        message: signingPreflightMessage,
      });
      const trusted = await verifyEd25519ReleaseSignature({
        trustKeysJson,
        publisher,
        signingKeyId,
        signature,
        message: signingPreflightMessage,
      });
      if (!trusted) issues.push("signer_trust_mismatch");
    } catch {
      issues.push("signer_trust_mismatch");
    }

    try {
      const revoked = await env.CONCLAVE_DB.prepare(
        "SELECT key_id FROM release_signing_key_revocations WHERE key_id = ?1",
      )
        .bind(signingKeyId)
        .first<{ key_id: string }>();
      if (revoked) issues.push("signing_key_revoked");
    } catch {
      // A failed revocation lookup must fail closed without disclosing DB details.
      issues.push("revocation_check_failed");
    }
  }

  return {
    ready: issues.length === 0,
    ...(publisher ? { publisher } : {}),
    ...(signingKeyId ? { signingKeyId } : {}),
    issues,
  };
}
export type {
  ApprovedLogicalWorkerInput,
  ToolProfileAcceptanceEvidence,
  ToolProfileChannel,
  ToolProfileDefinitionInput,
  ToolProfileLifecycle,
  ToolProfileRegistryEnvironment,
  ToolProfileReleaseIdentity,
} from "./tool-profile-validation.js";

async function requireDefinition(
  db: D1Database,
  profileDefinitionId: string,
): Promise<{
  worker_type_id: string;
  provider_tool_name: string;
  lifecycle_state: string;
}> {
  const row = await db
    .prepare(
      `SELECT worker_type_id, provider_tool_name, lifecycle_state
         FROM tool_profile_definitions
        WHERE profile_definition_id = ?1`,
    )
    .bind(profileDefinitionId)
    .first<{
      worker_type_id: string;
      provider_tool_name: string;
      lifecycle_state: string;
    }>();
  if (!row)
    throw new ToolProfileRegistryError(
      404,
      "Tool Profile definition was not found",
    );
  if (row.lifecycle_state !== "active") {
    throw new ToolProfileRegistryError(
      409,
      "Tool Profile definition is retired",
    );
  }
  return row;
}

export async function createToolProfileDefinition(
  db: D1Database,
  input: ToolProfileDefinitionInput,
): Promise<void> {
  validateId(input.profileDefinitionId, "profileDefinitionId");
  validateId(input.workerTypeId, "workerTypeId");
  if (
    input.displayName.trim().length < 1 ||
    input.displayName.length > 128 ||
    input.providerToolName.trim().length < 1 ||
    input.providerToolName.length > 128
  ) {
    throw new ToolProfileRegistryError(
      400,
      "Tool Profile definition fields are invalid",
    );
  }
  const now = new Date().toISOString();
  try {
    await db
      .prepare(
        `INSERT INTO tool_profile_definitions (
           profile_definition_id, worker_type_id, display_name,
           provider_tool_name, engine_family, schema_version,
           created_by_user_id, created_at, updated_at
         ) VALUES (?1, ?2, ?3, ?4, 'cli', 1, ?5, ?6, ?6)`,
      )
      .bind(
        input.profileDefinitionId,
        input.workerTypeId,
        input.displayName.trim(),
        input.providerToolName.trim(),
        input.actorUserId,
        now,
      )
      .run();
  } catch {
    throw new ToolProfileRegistryError(
      409,
      "Logical Worker is missing or Tool Profile definition already exists",
    );
  }
}

/** Creates an approved catalog mapping and its Profile definition atomically. */
export async function createApprovedLogicalWorker(
  db: D1Database,
  input: ApprovedLogicalWorkerInput,
): Promise<void> {
  validateId(input.workerTypeId, "workerTypeId");
  validateId(input.profileDefinitionId, "profileDefinitionId");
  if (
    input.displayName.trim().length < 1 ||
    input.displayName.length > 120 ||
    input.description.length > 500 ||
    input.providerToolName.trim().length < 1 ||
    input.providerToolName.length > 64 ||
    !channelNames.has(input.releaseStage) ||
    !Number.isInteger(input.sortOrder) ||
    input.sortOrder < 0 ||
    input.sortOrder > 10_000 ||
    input.capabilities.length > 32 ||
    input.capabilities.length === 0 ||
    input.capabilities.some(
      (capability) => !productCapabilities.has(capability),
    ) ||
    new Set(input.capabilities).size !== input.capabilities.length
  ) {
    throw new ToolProfileRegistryError(
      400,
      "Logical Worker catalog fields are invalid",
    );
  }
  const now = new Date().toISOString();
  try {
    await db.batch([
      db
        .prepare(
          `INSERT INTO worker_catalog (
        worker_type_id, display_name, description, lifecycle_state,
        engine_family, visibility_state, release_stage, capabilities_json,
        sort_order, created_at, updated_at
      ) VALUES (?1, ?2, ?3, 'active', 'cli', 'visible', ?4, ?5, ?6, ?7, ?7)`,
        )
        .bind(
          input.workerTypeId,
          input.displayName.trim(),
          input.description,
          input.releaseStage,
          JSON.stringify(input.capabilities),
          input.sortOrder,
          now,
        ),
      db
        .prepare(
          `INSERT INTO tool_profile_definitions (
        profile_definition_id, worker_type_id, display_name, provider_tool_name,
        engine_family, schema_version, created_by_user_id, created_at, updated_at
      ) VALUES (?1, ?2, ?3, ?4, 'cli', 1, ?5, ?6, ?6)`,
        )
        .bind(
          input.profileDefinitionId,
          input.workerTypeId,
          input.displayName.trim(),
          input.providerToolName.trim(),
          input.actorUserId,
          now,
        ),
    ]);
  } catch {
    throw new ToolProfileRegistryError(
      409,
      "Logical Worker or Profile definition already exists",
    );
  }
}

export async function createDraftToolProfileRelease(
  db: D1Database,
  identity: ToolProfileReleaseIdentity,
  input: unknown,
  actorUserId: string,
): Promise<{ payloadDigest: string; status: "draft" }> {
  validateId(identity.profileDefinitionId, "profileDefinitionId");
  validateVersion(identity.releaseVersion);
  const { profile, payload } = parseProfile(input, identity);
  const definition = await requireDefinition(db, identity.profileDefinitionId);
  if (
    definition.worker_type_id !== profile.logicalWorkerTypeId ||
    !profile.providerTool.executableCandidates.includes(
      definition.provider_tool_name,
    )
  ) {
    throw new ToolProfileRegistryError(
      400,
      "Profile logical Worker does not match its definition",
    );
  }
  const digest = await profileDigest(payload);
  const now = new Date().toISOString();
  try {
    await db
      .prepare(
        `INSERT INTO tool_profile_releases (
           profile_definition_id, release_version, worker_type_id,
           lifecycle_state, schema_version, engine_family,
           engine_compatibility_min, engine_compatibility_max_exclusive,
           payload_json, payload_digest, created_by_user_id,
           updated_by_user_id, created_at, updated_at
         ) VALUES (?1, ?2, ?3, 'draft', 1, 'cli', ?4, ?5, ?6, ?7, ?8, ?8, ?9, ?9)`,
      )
      .bind(
        identity.profileDefinitionId,
        identity.releaseVersion,
        profile.logicalWorkerTypeId,
        profile.engineCompatibility.min,
        profile.engineCompatibility.maxExclusive,
        payload,
        digest,
        actorUserId,
        now,
      )
      .run();
  } catch {
    throw new ToolProfileRegistryError(
      409,
      "Tool Profile release version already exists",
    );
  }
  return { payloadDigest: digest, status: "draft" };
}

export async function updateDraftToolProfilePayload(
  db: D1Database,
  identity: ToolProfileReleaseIdentity,
  input: unknown,
  actorUserId: string,
  expectedBaseDigest?: string,
): Promise<{ payloadDigest: string }> {
  validateId(identity.profileDefinitionId, "profileDefinitionId");
  validateVersion(identity.releaseVersion);

  const existing = await db
    .prepare(
      `SELECT payload_digest, lifecycle_state FROM tool_profile_releases
        WHERE profile_definition_id = ?1 AND release_version = ?2`,
    )
    .bind(identity.profileDefinitionId, identity.releaseVersion)
    .first<{ payload_digest: string; lifecycle_state: string }>();

  if (!existing) {
    throw new ToolProfileRegistryError(
      404,
      "Tool Profile draft release not found",
    );
  }

  if (existing.lifecycle_state !== "draft") {
    throw new ToolProfileRegistryError(
      409,
      "Only draft Profile releases can be edited",
    );
  }

  if (expectedBaseDigest && existing.payload_digest !== expectedBaseDigest) {
    throw new ToolProfileRegistryError(
      409,
      `Tool Profile draft conflict: expected base digest ${expectedBaseDigest.substring(0, 16)}... does not match current Cloud digest ${existing.payload_digest.substring(0, 16)}...`,
    );
  }

  const { profile, payload } = parseProfile(input, identity);
  const definition = await requireDefinition(db, identity.profileDefinitionId);
  if (
    definition.worker_type_id !== profile.logicalWorkerTypeId ||
    !profile.providerTool.executableCandidates.includes(
      definition.provider_tool_name,
    )
  ) {
    throw new ToolProfileRegistryError(
      400,
      "Profile logical Worker does not match its definition",
    );
  }
  const digest = await profileDigest(payload);
  const now = new Date().toISOString();
  const result = await db
    .prepare(
      `UPDATE tool_profile_releases
          SET worker_type_id = ?1, schema_version = 1, engine_family = 'cli',
              engine_compatibility_min = ?2,
              engine_compatibility_max_exclusive = ?3,
              payload_json = ?4, payload_digest = ?5,
              updated_by_user_id = ?6, updated_at = ?7
        WHERE profile_definition_id = ?8 AND release_version = ?9
          AND lifecycle_state = 'draft' AND published_at IS NULL`,
    )
    .bind(
      profile.logicalWorkerTypeId,
      profile.engineCompatibility.min,
      profile.engineCompatibility.maxExclusive,
      payload,
      digest,
      actorUserId,
      now,
      identity.profileDefinitionId,
      identity.releaseVersion,
    )
    .run();
  if (!result.meta.changes) {
    throw new ToolProfileRegistryError(
      409,
      "Only draft Profile releases can be edited",
    );
  }
  return { payloadDigest: digest };
}

/** Stores verified local execution qualification against the current draft. */
export async function submitToolProfileLocalQualification(
  db: D1Database,
  identity: ToolProfileReleaseIdentity,
  input: unknown,
  actorUserId: string,
): Promise<{
  qualificationEvidenceId: string;
  status: "qualified";
  payloadDigest: string;
}> {
  validateId(identity.profileDefinitionId, "profileDefinitionId");
  validateVersion(identity.releaseVersion);
  const release = await db
    .prepare(
      `SELECT payload_digest, payload_json, worker_type_id,
              lifecycle_state, published_at
         FROM tool_profile_releases
        WHERE profile_definition_id = ?1 AND release_version = ?2`,
    )
    .bind(identity.profileDefinitionId, identity.releaseVersion)
    .first<{
      payload_digest: string;
      payload_json: string;
      worker_type_id: string;
      lifecycle_state: ToolProfileLifecycle;
      published_at: string | null;
    }>();

  if (!release) {
    throw new ToolProfileRegistryError(
      404,
      "Tool Profile release was not found",
    );
  }
  if (release.lifecycle_state !== "draft" || release.published_at !== null) {
    throw new ToolProfileRegistryError(
      409,
      "Local qualification can only be submitted for a mutable draft release",
    );
  }

  const profile = parseProfile(
    JSON.parse(release.payload_json),
    identity,
  ).profile;
  if (profile.logicalWorkerTypeId !== release.worker_type_id) {
    throw new ToolProfileRegistryError(
      409,
      "Profile logical Worker does not match the release record",
    );
  }
  const qualifiedEvidence = validateToolProfileAcceptanceEvidence(
    input,
    {
      identity,
      payloadDigest: release.payload_digest,
      profile,
    },
    "local qualification",
  );
  const qualificationEvidenceId = crypto.randomUUID();
  const submittedAt = new Date().toISOString();
  await db
    .prepare(
      `INSERT INTO tool_profile_local_qualification_evidence (
         id, profile_definition_id, release_version, payload_digest,
         engine_version, provider_tool_version, evidence_json,
         submitted_by_user_id, qualified_at, submitted_at
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)`,
    )
    .bind(
      qualificationEvidenceId,
      identity.profileDefinitionId,
      identity.releaseVersion,
      release.payload_digest,
      qualifiedEvidence.engineVersion,
      qualifiedEvidence.providerToolVersion,
      JSON.stringify(qualifiedEvidence),
      actorUserId,
      qualifiedEvidence.acceptedAt,
      submittedAt,
    )
    .run();

  return {
    qualificationEvidenceId,
    status: "qualified",
    payloadDigest: release.payload_digest,
  };
}

export async function publishDraftToolProfileRelease(
  env: ToolProfileRegistryEnvironment,
  identity: ToolProfileReleaseIdentity,
  actorUserId: string,
  qualificationEvidenceId: string,
): Promise<{
  payloadDigest: string;
  publishedAt: string;
  status: "testing";
  signature: string;
  signingKeyId: string;
  publisher: string;
  qualificationEvidenceId: string;
}> {
  validateId(identity.profileDefinitionId, "profileDefinitionId");
  validateVersion(identity.releaseVersion);
  if (
    typeof qualificationEvidenceId !== "string" ||
    !qualificationEvidenceId.trim() ||
    qualificationEvidenceId.length > 128
  ) {
    throw new ToolProfileRegistryError(
      409,
      "A stored local qualificationEvidenceId is required for publication",
    );
  }

  const row = await env.CONCLAVE_DB.prepare(
    `SELECT payload_json, payload_digest, lifecycle_state, published_at, worker_type_id
         FROM tool_profile_releases
        WHERE profile_definition_id = ?1 AND release_version = ?2`,
  )
    .bind(identity.profileDefinitionId, identity.releaseVersion)
    .first<{
      payload_json: string;
      payload_digest: string;
      lifecycle_state: ToolProfileLifecycle;
      published_at: string | null;
      worker_type_id: string;
    }>();
  if (!row)
    throw new ToolProfileRegistryError(
      404,
      "Tool Profile release was not found",
    );
  if (row.lifecycle_state !== "draft" || row.published_at !== null) {
    throw new ToolProfileRegistryError(
      409,
      "Only draft Profile releases can be published",
    );
  }
  const parsed = parseProfile(JSON.parse(row.payload_json), identity);
  validateProviderCompatibilityForPublication(parsed.profile);
  if (parsed.profile.logicalWorkerTypeId !== row.worker_type_id) {
    throw new ToolProfileRegistryError(
      409,
      "Profile logical Worker does not match the release record",
    );
  }
  const actualDigest = await profileDigest(parsed.payload);
  if (actualDigest !== row.payload_digest) {
    throw new ToolProfileRegistryError(
      409,
      "Draft Profile digest does not match its payload",
    );
  }

  const qualificationRow = await env.CONCLAVE_DB.prepare(
    `SELECT payload_digest, evidence_json
       FROM tool_profile_local_qualification_evidence
      WHERE id = ?1 AND profile_definition_id = ?2 AND release_version = ?3`,
  )
    .bind(
      qualificationEvidenceId,
      identity.profileDefinitionId,
      identity.releaseVersion,
    )
    .first<{ payload_digest: string; evidence_json: string }>();
  if (!qualificationRow || qualificationRow.payload_digest !== actualDigest) {
    throw new ToolProfileRegistryError(
      409,
      "A complete local qualification for this exact draft payload is required before publication",
    );
  }
  validateToolProfileAcceptanceEvidence(
    JSON.parse(qualificationRow.evidence_json),
    {
      identity,
      payloadDigest: actualDigest,
      profile: parsed.profile,
    },
    "local qualification",
  );

  const preflight = await toolProfileSigningPreflight(env);
  if (!preflight.ready) {
    throw new ToolProfileRegistryError(
      503,
      `Tool Profile release signing is not ready (${preflight.issues.join(", ")})`,
    );
  }
  const publisher = preflight.publisher!;
  const signingKeyId = preflight.signingKeyId!;
  const privateKey = env.CONCLAVE_RELEASE_PRIVATE_KEY!;

  const signingMessage = toolProfileReleaseSigningMessage({
    publisher,
    signingKeyId,
    payloadDigest: actualDigest,
    profile: parsed.profile,
  });

  const signature = signEd25519ReleaseMessage({
    privateKeyBase64OrPem: privateKey,
    message: signingMessage,
  });

  const signatureValid = await verifyEd25519ReleaseSignature({
    trustKeysJson: env.CONCLAVE_RELEASE_TRUST_KEYS_JSON,
    publisher,
    signingKeyId,
    signature,
    message: signingMessage,
  });

  if (!signatureValid) {
    throw new ToolProfileRegistryError(
      500,
      "Cloud signing boundary failed to produce a valid Ed25519 release signature",
    );
  }

  const publishedAt = new Date().toISOString();
  const result = await env.CONCLAVE_DB.prepare(
    `UPDATE tool_profile_releases
          SET lifecycle_state = 'testing', signature = ?1, signing_key_id = ?2,
              publisher = ?3, published_at = ?4, updated_by_user_id = ?5,
              lifecycle_reason = ?11, updated_at = ?4
        WHERE profile_definition_id = ?6 AND release_version = ?7
          AND lifecycle_state = 'draft' AND published_at IS NULL
          AND payload_digest = ?8
          AND NOT EXISTS (
            SELECT 1 FROM release_signing_key_revocations revoked
             WHERE revoked.key_id = ?9
          )
          AND EXISTS (
            SELECT 1 FROM tool_profile_local_qualification_evidence qualification
             WHERE qualification.id = ?10
               AND qualification.profile_definition_id = ?6
               AND qualification.release_version = ?7
               AND qualification.payload_digest = ?8
          )`,
  )
    .bind(
      signature,
      signingKeyId,
      publisher,
      publishedAt,
      actorUserId,
      identity.profileDefinitionId,
      identity.releaseVersion,
      row.payload_digest,
      signingKeyId,
      qualificationEvidenceId,
      `Published with local sandbox qualification ${qualificationEvidenceId}`,
    )
    .run();
  if (!result.meta.changes) {
    throw new ToolProfileRegistryError(
      409,
      "Tool Profile draft changed before publication",
    );
  }
  return {
    payloadDigest: row.payload_digest,
    publishedAt,
    status: "testing",
    signature,
    signingKeyId,
    publisher,
    qualificationEvidenceId,
  };
}

export async function promoteToolProfileRelease(
  db: D1Database,
  identity: ToolProfileReleaseIdentity,
  channel: ToolProfileChannel,
  actorUserId: string,
  acceptanceEvidenceId?: string,
): Promise<{
  channel: ToolProfileChannel;
  releaseVersion: number;
  action: "promoted" | "rolled_back";
  acceptanceEvidenceId?: string;
}> {
  validateId(identity.profileDefinitionId, "profileDefinitionId");
  validateVersion(identity.releaseVersion);
  if (!channelNames.has(channel))
    throw new ToolProfileRegistryError(400, "channel is invalid");
  const row = await db
    .prepare(
      `SELECT lifecycle_state, published_at, payload_digest, payload_json,
              worker_type_id
         FROM tool_profile_releases
        WHERE profile_definition_id = ?1 AND release_version = ?2`,
    )
    .bind(identity.profileDefinitionId, identity.releaseVersion)
    .first<{
      lifecycle_state: ToolProfileLifecycle;
      published_at: string | null;
      payload_digest: string;
      payload_json: string;
      worker_type_id: string;
    }>();
  if (!row)
    throw new ToolProfileRegistryError(
      404,
      "Tool Profile release was not found",
    );
  if (
    !row.published_at ||
    ["draft", "retired", "revoked"].includes(row.lifecycle_state)
  ) {
    throw new ToolProfileRegistryError(
      409,
      "Tool Profile release is not eligible for promotion",
    );
  }
  if (channel === "stable") {
    if (
      typeof acceptanceEvidenceId !== "string" ||
      !acceptanceEvidenceId.trim() ||
      acceptanceEvidenceId.length > 128
    ) {
      throw new ToolProfileRegistryError(
        400,
        "A stored acceptanceEvidenceId is required for stable promotion",
      );
    }
    const profile = parseProfile(
      JSON.parse(row.payload_json),
      identity,
    ).profile;
    if (row.worker_type_id !== profile.logicalWorkerTypeId) {
      throw new ToolProfileRegistryError(
        409,
        "Stable promotion release identity is inconsistent",
      );
    }
    const evidenceRow = await db
      .prepare(
        `SELECT id, payload_digest, engine_version, provider_tool_version,
                evidence_json, accepted_at
           FROM tool_profile_acceptance_evidence
          WHERE id = ?1 AND profile_definition_id = ?2
            AND release_version = ?3 AND payload_digest = ?4`,
      )
      .bind(
        acceptanceEvidenceId,
        identity.profileDefinitionId,
        identity.releaseVersion,
        row.payload_digest,
      )
      .first<{
        id: string;
        payload_digest: string;
        engine_version: string;
        provider_tool_version: string;
        evidence_json: string;
        accepted_at: string;
      }>();
    if (!evidenceRow) {
      throw new ToolProfileRegistryError(
        409,
        "Stored acceptance evidence does not qualify for this release",
      );
    }
    let evidenceInput: unknown;
    try {
      evidenceInput = JSON.parse(evidenceRow.evidence_json);
    } catch {
      throw new ToolProfileRegistryError(
        409,
        "Stored acceptance evidence is invalid",
      );
    }
    let acceptedEvidence: ToolProfileAcceptanceEvidence;
    try {
      acceptedEvidence = validateToolProfileAcceptanceEvidence(evidenceInput, {
        identity,
        payloadDigest: row.payload_digest,
        profile,
      });
    } catch {
      throw new ToolProfileRegistryError(
        409,
        "Stored acceptance evidence does not qualify for this release",
      );
    }
    if (
      evidenceRow.id !== acceptanceEvidenceId ||
      evidenceRow.payload_digest !== acceptedEvidence.profileDigest ||
      evidenceRow.engine_version !== acceptedEvidence.engineVersion ||
      evidenceRow.provider_tool_version !==
        acceptedEvidence.providerToolVersion ||
      evidenceRow.accepted_at !== acceptedEvidence.acceptedAt
    ) {
      throw new ToolProfileRegistryError(
        409,
        "Stored acceptance evidence metadata is inconsistent",
      );
    }
  } else if (acceptanceEvidenceId !== undefined) {
    throw new ToolProfileRegistryError(
      400,
      "Acceptance evidence is only referenced for stable promotion",
    );
  }
  if (
    (channel === "testing" && row.lifecycle_state !== "testing") ||
    (channel === "beta" &&
      !["testing", "beta"].includes(row.lifecycle_state)) ||
    (channel === "stable" &&
      !["testing", "beta", "stable"].includes(row.lifecycle_state))
  ) {
    throw new ToolProfileRegistryError(
      409,
      "Tool Profile release cannot enter the requested channel",
    );
  }
  let targetState: ToolProfileLifecycle = channel;
  const allowedStates: Record<ToolProfileChannel, ToolProfileLifecycle[]> = {
    testing: ["testing"],
    beta: ["beta"],
    stable: ["stable"],
  };
  if (channel === "beta" && row.lifecycle_state === "testing") {
    targetState = "beta";
  } else if (channel === "beta") {
    targetState = row.lifecycle_state;
  } else if (
    channel === "stable" &&
    ["testing", "beta"].includes(row.lifecycle_state)
  ) {
    targetState = "stable";
  }
  if (!allowedStates[channel].includes(targetState)) {
    throw new ToolProfileRegistryError(
      409,
      "Tool Profile release cannot enter the requested channel",
    );
  }
  const current = await db
    .prepare(
      `SELECT release_version FROM tool_profile_channel_pointers
        WHERE profile_definition_id = ?1 AND channel = ?2`,
    )
    .bind(identity.profileDefinitionId, channel)
    .first<{ release_version: number }>();
  if (current?.release_version === identity.releaseVersion) {
    return {
      channel,
      releaseVersion: identity.releaseVersion,
      action: "promoted",
      ...(acceptanceEvidenceId ? { acceptanceEvidenceId } : {}),
    };
  }
  const action =
    channel === "stable" &&
    current &&
    identity.releaseVersion < current.release_version
      ? "rolled_back"
      : "promoted";
  const now = new Date().toISOString();
  const statements = [];
  if (row.lifecycle_state !== targetState) {
    statements.push(
      db
        .prepare(
          `UPDATE tool_profile_releases
              SET lifecycle_state = ?1, updated_by_user_id = ?2,
                  lifecycle_reason = ?3, updated_at = ?4
            WHERE profile_definition_id = ?5 AND release_version = ?6
              AND lifecycle_state = ?7 AND published_at IS NOT NULL`,
        )
        .bind(
          targetState,
          actorUserId,
          `${action} to ${channel}${acceptanceEvidenceId ? ` using acceptance evidence ${acceptanceEvidenceId}` : ""}`,
          now,
          identity.profileDefinitionId,
          identity.releaseVersion,
          row.lifecycle_state,
        ),
    );
  }
  statements.push(
    db
      .prepare(
        `INSERT INTO tool_profile_channel_pointers (
           profile_definition_id, channel, release_version,
           modified_by_user_id, updated_at
         ) SELECT ?1, ?2, ?3, ?4, ?5
           WHERE EXISTS (
             SELECT 1 FROM tool_profile_releases
              WHERE profile_definition_id = ?1 AND release_version = ?3
                AND lifecycle_state = ?6 AND published_at IS NOT NULL
           )
         ON CONFLICT(profile_definition_id, channel) DO UPDATE SET
           release_version = excluded.release_version,
           modified_by_user_id = excluded.modified_by_user_id,
           updated_at = excluded.updated_at`,
      )
      .bind(
        identity.profileDefinitionId,
        channel,
        identity.releaseVersion,
        actorUserId,
        now,
        targetState,
      ),
  );
  if (channel === "stable" && acceptanceEvidenceId) {
    statements.push(
      db
        .prepare(
          `UPDATE tool_profile_release_audit
              SET details_json = json_set(
                details_json, '$.acceptanceEvidenceId', ?1
              )
            WHERE id = (
              SELECT id FROM tool_profile_release_audit
               WHERE profile_definition_id = ?2 AND release_version = ?3
                 AND actor_user_id = ?4 AND channel = 'stable'
                 AND created_at = ?5
               ORDER BY created_at DESC LIMIT 1
            )`,
        )
        .bind(
          acceptanceEvidenceId,
          identity.profileDefinitionId,
          identity.releaseVersion,
          actorUserId,
          now,
        ),
    );
  }
  const results = await db.batch(statements);
  if (!results.at(-1)?.meta.changes) {
    throw new ToolProfileRegistryError(
      409,
      "Tool Profile channel promotion was rejected",
    );
  }
  return {
    channel,
    releaseVersion: identity.releaseVersion,
    action,
    ...(acceptanceEvidenceId ? { acceptanceEvidenceId } : {}),
  };
}

export async function changeToolProfileLifecycle(
  db: D1Database,
  identity: ToolProfileReleaseIdentity,
  lifecycle: "retired" | "revoked",
  actorUserId: string,
  reason: string,
): Promise<{ lifecycleState: "retired" | "revoked" }> {
  validateId(identity.profileDefinitionId, "profileDefinitionId");
  validateVersion(identity.releaseVersion);
  if (!reason.trim() || reason.length > 512) {
    throw new ToolProfileRegistryError(400, "A lifecycle reason is required");
  }
  if (lifecycle === "retired") {
    const selected = await db
      .prepare(
        `SELECT channel FROM tool_profile_channel_pointers
          WHERE profile_definition_id = ?1 AND release_version = ?2 LIMIT 1`,
      )
      .bind(identity.profileDefinitionId, identity.releaseVersion)
      .first<{ channel: string }>();
    if (selected) {
      throw new ToolProfileRegistryError(
        409,
        "Move the active channel pointer before retiring this release",
      );
    }
  }
  const now = new Date().toISOString();
  const revokedAt = lifecycle === "revoked" ? now : null;
  const result = await db
    .prepare(
      `UPDATE tool_profile_releases
          SET lifecycle_state = ?1, lifecycle_reason = ?2,
              updated_by_user_id = ?3, revoked_at = ?4, updated_at = ?5
        WHERE profile_definition_id = ?6 AND release_version = ?7
          AND lifecycle_state IN ('draft', 'testing', 'beta', 'stable')`,
    )
    .bind(
      lifecycle,
      reason.trim(),
      actorUserId,
      revokedAt,
      now,
      identity.profileDefinitionId,
      identity.releaseVersion,
    )
    .run();
  if (!result.meta.changes) {
    throw new ToolProfileRegistryError(
      409,
      "Tool Profile release cannot enter the requested lifecycle state",
    );
  }
  return { lifecycleState: lifecycle };
}

export async function listToolProfileReleases(
  db: D1Database,
  profileDefinitionId: string,
): Promise<{ releases: Record<string, unknown>[] }> {
  validateId(profileDefinitionId, "profileDefinitionId");
  const rows = await db
    .prepare(
      `SELECT release_version, worker_type_id, lifecycle_state, schema_version,
              engine_family, engine_compatibility_min,
              engine_compatibility_max_exclusive, payload_json, payload_digest,
              signature, signing_key_id, publisher, published_at, lifecycle_reason,
              revoked_at, created_at, updated_at,
              (SELECT evidence_json FROM tool_profile_acceptance_evidence evidence
                WHERE evidence.profile_definition_id = release.profile_definition_id
                  AND evidence.release_version = release.release_version
                ORDER BY evidence.submitted_at DESC LIMIT 1)
                AS acceptance_evidence_json
         FROM tool_profile_releases
         AS release
        WHERE profile_definition_id = ?1
        ORDER BY release_version DESC LIMIT 100`,
    )
    .bind(profileDefinitionId)
    .all<{
      release_version: number;
      worker_type_id: string;
      lifecycle_state: ToolProfileLifecycle;
      schema_version: number;
      engine_family: string;
      engine_compatibility_min: string;
      engine_compatibility_max_exclusive: string;
      payload_json: string;
      payload_digest: string;
      signature: string | null;
      signing_key_id: string | null;
      publisher: string | null;
      published_at: string | null;
      lifecycle_reason: string | null;
      revoked_at: string | null;
      created_at: string;
      updated_at: string;
      acceptance_evidence_json: string | null;
    }>();
  return {
    releases: (rows.results ?? []).map((row) => ({
      releaseVersion: row.release_version,
      workerTypeId: row.worker_type_id,
      lifecycleState: row.lifecycle_state,
      schemaVersion: row.schema_version,
      engineFamily: row.engine_family,
      engineCompatibility: {
        min: row.engine_compatibility_min,
        maxExclusive: row.engine_compatibility_max_exclusive,
      },
      profile: JSON.parse(row.payload_json),
      payloadDigest: row.payload_digest,
      signature: row.signature,
      signingKeyId: row.signing_key_id,
      publisher: row.publisher,
      publishedAt: row.published_at,
      acceptanceEvidence: row.acceptance_evidence_json
        ? JSON.parse(row.acceptance_evidence_json)
        : null,
      lifecycleReason: row.lifecycle_reason,
      revokedAt: row.revoked_at,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    })),
  };
}

export async function resolveToolProfileChannels(
  db: D1Database,
  workerTypeId: string,
  channel: ToolProfileChannel = "stable",
): Promise<{
  profiles: Record<string, unknown>[];
}> {
  validateId(workerTypeId, "workerTypeId");
  if (channel !== undefined && !channelNames.has(channel)) {
    throw new ToolProfileRegistryError(400, "channel is invalid");
  }
  const rows = await db
    .prepare(
      `SELECT definition.profile_definition_id, definition.worker_type_id,
              definition.display_name, definition.provider_tool_name,
              pointer.channel, release.release_version,
              release.payload_json, release.payload_digest,
              release.signature, release.signing_key_id, release.publisher,
              release.schema_version, release.engine_family,
              release.engine_compatibility_min,
              release.engine_compatibility_max_exclusive,
              release.published_at
         FROM tool_profile_channel_pointers pointer
         JOIN tool_profile_definitions definition
           ON definition.profile_definition_id = pointer.profile_definition_id
         JOIN worker_catalog worker
           ON worker.worker_type_id = definition.worker_type_id
         JOIN tool_profile_releases release
           ON release.profile_definition_id = pointer.profile_definition_id
          AND release.release_version = pointer.release_version
        WHERE definition.lifecycle_state = 'active'
          AND worker.lifecycle_state = 'active'
          AND worker.visibility_state = 'visible'
          AND release.lifecycle_state = pointer.channel
          AND (pointer.channel = 'testing'
               OR (pointer.channel = 'beta' AND worker.release_stage IN ('beta', 'stable'))
               OR (pointer.channel = 'stable' AND worker.release_stage = 'stable'))
          AND NOT EXISTS (
            SELECT 1 FROM release_signing_key_revocations revoked
             WHERE revoked.key_id = release.signing_key_id
          )
          AND (?1 IS NULL OR definition.worker_type_id = ?1)
          AND (?2 IS NULL OR pointer.channel = ?2)
        ORDER BY definition.worker_type_id, definition.profile_definition_id,
                 CASE pointer.channel WHEN 'stable' THEN 0 WHEN 'beta' THEN 1 ELSE 2 END
        LIMIT 64`,
    )
    .bind(workerTypeId, channel)
    .all<{
      profile_definition_id: string;
      worker_type_id: string;
      display_name: string;
      provider_tool_name: string;
      channel: ToolProfileChannel;
      release_version: number;
      payload_json: string;
      payload_digest: string;
      signature: string;
      signing_key_id: string;
      publisher: string;
      schema_version: number;
      engine_family: string;
      engine_compatibility_min: string;
      engine_compatibility_max_exclusive: string;
      published_at: string;
    }>();
  return {
    profiles: (rows.results ?? []).map((row) => {
      const profile = JSON.parse(row.payload_json);
      const { profile: validatedProfile } = parseProfile(profile, {
        profileDefinitionId: row.profile_definition_id,
        releaseVersion: row.release_version,
      });
      return {
        profileDefinitionId: row.profile_definition_id,
        workerTypeId: row.worker_type_id,
        displayName: row.display_name,
        providerToolName: validatedProfile.providerTool.name,
        channel: row.channel,
        releaseVersion: row.release_version,
        profile,
        payloadDigest: row.payload_digest,
        signature: row.signature,
        signingKeyId: row.signing_key_id,
        publisher: row.publisher,
        schemaVersion: row.schema_version,
        engineFamily: row.engine_family,
        engineCompatibility: {
          min: row.engine_compatibility_min,
          maxExclusive: row.engine_compatibility_max_exclusive,
        },
        publishedAt: row.published_at,
      };
    }),
  };
}

/** Lists active visible logical Workers independently of release availability. */
export async function resolveLogicalWorkerCatalog(
  db: D1Database,
  workerTypeId?: string,
  channel: ToolProfileChannel = "stable",
): Promise<WorkerDescriptor[]> {
  if (workerTypeId !== undefined) validateId(workerTypeId, "workerTypeId");
  if (!channelNames.has(channel))
    throw new ToolProfileRegistryError(400, "channel is invalid");
  const rows = await db
    .prepare(
      `SELECT worker.worker_type_id, worker.display_name, worker.description,
            worker.engine_family, worker.visibility_state, worker.release_stage,
            worker.capabilities_json, worker.sort_order,
            definition.profile_definition_id, definition.provider_tool_name
       FROM worker_catalog worker
       JOIN tool_profile_definitions definition
         ON definition.worker_type_id = worker.worker_type_id
        AND definition.lifecycle_state = 'active'
      WHERE worker.lifecycle_state = 'active'
        AND worker.visibility_state = 'visible'
        AND (?2 IS NULL OR worker.worker_type_id = ?2)
        AND (?1 = 'testing' OR (?1 = 'beta' AND worker.release_stage IN ('beta','stable'))
             OR (?1 = 'stable' AND worker.release_stage = 'stable'))
      ORDER BY worker.sort_order, worker.worker_type_id, definition.profile_definition_id
      LIMIT 64`,
    )
    .bind(channel, workerTypeId ?? null)
    .all<{
      worker_type_id: string;
      display_name: string;
      description: string;
      engine_family: string;
      visibility_state: string;
      release_stage: string;
      capabilities_json: string;
      sort_order: number;
      profile_definition_id: string;
      provider_tool_name: string;
    }>();
  return (rows.results ?? []).map((row) => {
    let capabilities: unknown;
    try {
      capabilities = JSON.parse(row.capabilities_json);
    } catch {
      throw new ToolProfileRegistryError(
        500,
        "logical Worker metadata is invalid",
      );
    }
    if (Array.isArray(capabilities)) {
      capabilities = capabilities.map((value) =>
        typeof value === "string"
          ? (retiredCapabilityAliases[value] ?? value)
          : value,
      );
    }
    if (
      !Array.isArray(capabilities) ||
      capabilities.length > 32 ||
      capabilities.some(
        (value) => typeof value !== "string" || !productCapabilities.has(value),
      )
    ) {
      throw new ToolProfileRegistryError(
        500,
        "logical Worker capabilities are invalid",
      );
    }
    try {
      return parseWorkerDescriptor({
        workerTypeId: row.worker_type_id,
        displayName: row.display_name,
        description: row.description,
        engineFamily: row.engine_family,
        visibilityState: row.visibility_state,
        releaseStage: row.release_stage,
        capabilities,
        sortOrder: row.sort_order,
        profileDefinitionId: row.profile_definition_id,
        providerToolName: row.provider_tool_name,
      });
    } catch {
      throw new ToolProfileRegistryError(
        500,
        "logical Worker descriptor is invalid",
      );
    }
  });
}

export async function setWorkspaceToolProfileChannel(
  db: D1Database,
  args: {
    workspaceId: string;
    channel: ToolProfileChannel;
    actorUserId: string;
  },
): Promise<{ workspaceId: string; channel: ToolProfileChannel }> {
  if (!channelNames.has(args.channel)) {
    throw new ToolProfileRegistryError(400, "channel is invalid");
  }
  const workspace = await db
    .prepare(
      "SELECT id FROM execution_workspaces WHERE id = ?1 AND status <> 'revoked'",
    )
    .bind(args.workspaceId)
    .first<{ id: string }>();
  if (!workspace) {
    throw new ToolProfileRegistryError(404, "Workspace not found");
  }
  await db
    .prepare(
      `INSERT INTO workspace_tool_profile_channels (
         workspace_id, channel, updated_by_user_id, updated_at
       ) VALUES (?1, ?2, ?3, ?4)
       ON CONFLICT(workspace_id) DO UPDATE SET
         channel = excluded.channel,
         updated_by_user_id = excluded.updated_by_user_id,
         updated_at = excluded.updated_at`,
    )
    .bind(
      args.workspaceId,
      args.channel,
      args.actorUserId,
      new Date().toISOString(),
    )
    .run();
  return { workspaceId: args.workspaceId, channel: args.channel };
}

export async function listToolProfileReleaseAudit(
  db: D1Database,
  identity: ToolProfileReleaseIdentity,
): Promise<{ events: Record<string, unknown>[] }> {
  validateId(identity.profileDefinitionId, "profileDefinitionId");
  validateVersion(identity.releaseVersion);
  const rows = await db
    .prepare(
      `SELECT actor_user_id, action, previous_release_version, channel,
              from_state, to_state, reason, details_json, created_at
         FROM tool_profile_release_audit
        WHERE profile_definition_id = ?1 AND release_version = ?2
        ORDER BY created_at, id LIMIT 500`,
    )
    .bind(identity.profileDefinitionId, identity.releaseVersion)
    .all<{
      actor_user_id: string | null;
      action: string;
      previous_release_version: number | null;
      channel: string | null;
      from_state: string | null;
      to_state: string | null;
      reason: string | null;
      details_json: string;
      created_at: string;
    }>();
  return {
    events: (rows.results ?? []).map((row) => ({
      actorUserId: row.actor_user_id,
      action: row.action,
      previousReleaseVersion: row.previous_release_version,
      channel: row.channel,
      fromState: row.from_state,
      toState: row.to_state,
      reason: row.reason,
      details: JSON.parse(row.details_json),
      createdAt: row.created_at,
    })),
  };
}

export interface AdminWorkerCatalogEntry {
  workerTypeId: string;
  displayName: string;
  description: string;
  lifecycleState: string;
  engineFamily: string;
  visibilityState: string;
  releaseStage: string;
  capabilities: string[];
  sortOrder: number;
  profileDefinitionId: string | null;
  providerToolName: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface ToolProfileDefinitionSummary {
  profileDefinitionId: string;
  workerTypeId: string;
  displayName: string;
  providerToolName: string;
  engineFamily: string;
  schemaVersion: number;
  lifecycleState: string;
  createdByUserId: string | null;
  createdAt: string;
  updatedAt: string;
  workerDisplayName?: string;
  workerReleaseStage?: string;
  latestReleaseVersion?: number | null;
  releaseCount?: number;
  channels: Partial<Record<ToolProfileChannel, number>>;
}

export interface ToolProfileChannelPointerRecord {
  profileDefinitionId: string;
  channel: ToolProfileChannel;
  releaseVersion: number;
  modifiedByUserId: string | null;
  updatedAt: string;
}

export interface ToolProfileAcceptanceEvidenceRecord {
  id: string;
  profileDefinitionId: string;
  releaseVersion: number;
  payloadDigest: string;
  engineVersion: string;
  providerToolVersion: string;
  evidence: unknown;
  submittedByUserId: string | null;
  acceptedAt: string;
  submittedAt: string;
}

export interface ToolProfileAuditEvent {
  id: string;
  profileDefinitionId: string;
  releaseVersion: number;
  actorUserId: string | null;
  actorDisplayName?: string | null;
  workerDisplayName?: string | null;
  action: string;
  previousReleaseVersion: number | null;
  channel: string | null;
  fromState: string | null;
  toState: string | null;
  reason: string | null;
  details: Record<string, unknown>;
  createdAt: string;
}

export async function listAdminWorkerCatalog(
  db: D1Database,
): Promise<{ workers: AdminWorkerCatalogEntry[] }> {
  const rows = await db
    .prepare(
      `SELECT worker.worker_type_id, worker.display_name, worker.description,
              worker.lifecycle_state, worker.engine_family, worker.visibility_state,
              worker.release_stage, worker.capabilities_json, worker.sort_order,
              worker.created_at, worker.updated_at,
              definition.profile_definition_id, definition.provider_tool_name
         FROM worker_catalog worker
         LEFT JOIN tool_profile_definitions definition
           ON definition.worker_type_id = worker.worker_type_id
          AND definition.lifecycle_state = 'active'
        ORDER BY worker.sort_order, worker.worker_type_id
        LIMIT 256`,
    )
    .all<{
      worker_type_id: string;
      display_name: string;
      description: string;
      lifecycle_state: string;
      engine_family: string;
      visibility_state: string;
      release_stage: string;
      capabilities_json: string;
      sort_order: number;
      created_at: string;
      updated_at: string;
      profile_definition_id: string | null;
      provider_tool_name: string | null;
    }>();
  return {
    workers: (rows.results ?? []).map((row) => {
      let capabilities: string[] = [];
      try {
        const parsed = JSON.parse(row.capabilities_json);
        if (Array.isArray(parsed)) capabilities = parsed;
      } catch {
        capabilities = [];
      }
      return {
        workerTypeId: row.worker_type_id,
        displayName: row.display_name,
        description: row.description,
        lifecycleState: row.lifecycle_state,
        engineFamily: row.engine_family,
        visibilityState: row.visibility_state,
        releaseStage: row.release_stage,
        capabilities,
        sortOrder: row.sort_order,
        profileDefinitionId: row.profile_definition_id,
        providerToolName: row.provider_tool_name,
        createdAt: row.created_at,
        updatedAt: row.updated_at,
      };
    }),
  };
}

export async function listToolProfileDefinitions(
  db: D1Database,
): Promise<{ definitions: ToolProfileDefinitionSummary[] }> {
  const [defRows, pointerRows] = await Promise.all([
    db
      .prepare(
        `SELECT def.profile_definition_id, def.worker_type_id, def.display_name,
                def.provider_tool_name, def.engine_family, def.schema_version,
                def.lifecycle_state, def.created_by_user_id, def.created_at, def.updated_at,
                worker.display_name AS worker_display_name,
                worker.release_stage AS worker_release_stage,
                (SELECT MAX(release_version) FROM tool_profile_releases r
                  WHERE r.profile_definition_id = def.profile_definition_id) AS latest_release_version,
                (SELECT COUNT(*) FROM tool_profile_releases r
                  WHERE r.profile_definition_id = def.profile_definition_id) AS release_count
           FROM tool_profile_definitions def
           JOIN worker_catalog worker
             ON worker.worker_type_id = def.worker_type_id
          ORDER BY def.profile_definition_id LIMIT 256`,
      )
      .all<{
        profile_definition_id: string;
        worker_type_id: string;
        display_name: string;
        provider_tool_name: string;
        engine_family: string;
        schema_version: number;
        lifecycle_state: string;
        created_by_user_id: string | null;
        created_at: string;
        updated_at: string;
        worker_display_name: string;
        worker_release_stage: string;
        latest_release_version: number | null;
        release_count: number;
      }>(),
    db
      .prepare(
        `SELECT profile_definition_id, channel, release_version
           FROM tool_profile_channel_pointers`,
      )
      .all<{
        profile_definition_id: string;
        channel: ToolProfileChannel;
        release_version: number;
      }>(),
  ]);

  const channelMap = new Map<
    string,
    Partial<Record<ToolProfileChannel, number>>
  >();
  for (const row of pointerRows.results ?? []) {
    let channels = channelMap.get(row.profile_definition_id);
    if (!channels) {
      channels = {};
      channelMap.set(row.profile_definition_id, channels);
    }
    channels[row.channel] = row.release_version;
  }

  return {
    definitions: (defRows.results ?? []).map((row) => ({
      profileDefinitionId: row.profile_definition_id,
      workerTypeId: row.worker_type_id,
      displayName: row.display_name,
      providerToolName: row.provider_tool_name,
      engineFamily: row.engine_family,
      schemaVersion: row.schema_version,
      lifecycleState: row.lifecycle_state,
      createdByUserId: row.created_by_user_id,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
      workerDisplayName: row.worker_display_name,
      workerReleaseStage: row.worker_release_stage,
      latestReleaseVersion: row.latest_release_version,
      releaseCount: row.release_count,
      channels: channelMap.get(row.profile_definition_id) ?? {},
    })),
  };
}

export async function getToolProfileDefinition(
  db: D1Database,
  profileDefinitionId: string,
): Promise<ToolProfileDefinitionSummary> {
  validateId(profileDefinitionId, "profileDefinitionId");
  const [row, pointerRows] = await Promise.all([
    db
      .prepare(
        `SELECT def.profile_definition_id, def.worker_type_id, def.display_name,
                def.provider_tool_name, def.engine_family, def.schema_version,
                def.lifecycle_state, def.created_by_user_id, def.created_at, def.updated_at,
                worker.display_name AS worker_display_name,
                worker.release_stage AS worker_release_stage,
                (SELECT MAX(release_version) FROM tool_profile_releases r
                  WHERE r.profile_definition_id = def.profile_definition_id) AS latest_release_version,
                (SELECT COUNT(*) FROM tool_profile_releases r
                  WHERE r.profile_definition_id = def.profile_definition_id) AS release_count
           FROM tool_profile_definitions def
           JOIN worker_catalog worker
             ON worker.worker_type_id = def.worker_type_id
          WHERE def.profile_definition_id = ?1`,
      )
      .bind(profileDefinitionId)
      .first<{
        profile_definition_id: string;
        worker_type_id: string;
        display_name: string;
        provider_tool_name: string;
        engine_family: string;
        schema_version: number;
        lifecycle_state: string;
        created_by_user_id: string | null;
        created_at: string;
        updated_at: string;
        worker_display_name: string;
        worker_release_stage: string;
        latest_release_version: number | null;
        release_count: number;
      }>(),
    db
      .prepare(
        `SELECT channel, release_version
           FROM tool_profile_channel_pointers
          WHERE profile_definition_id = ?1`,
      )
      .bind(profileDefinitionId)
      .all<{
        channel: ToolProfileChannel;
        release_version: number;
      }>(),
  ]);

  if (!row) {
    throw new ToolProfileRegistryError(
      404,
      "Tool Profile definition was not found",
    );
  }

  const channels: Partial<Record<ToolProfileChannel, number>> = {};
  for (const pointer of pointerRows.results ?? []) {
    channels[pointer.channel] = pointer.release_version;
  }

  return {
    profileDefinitionId: row.profile_definition_id,
    workerTypeId: row.worker_type_id,
    displayName: row.display_name,
    providerToolName: row.provider_tool_name,
    engineFamily: row.engine_family,
    schemaVersion: row.schema_version,
    lifecycleState: row.lifecycle_state,
    createdByUserId: row.created_by_user_id,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    workerDisplayName: row.worker_display_name,
    workerReleaseStage: row.worker_release_stage,
    latestReleaseVersion: row.latest_release_version,
    releaseCount: row.release_count,
    channels,
  };
}

export async function getToolProfileRelease(
  db: D1Database,
  identity: ToolProfileReleaseIdentity,
): Promise<Record<string, unknown>> {
  validateId(identity.profileDefinitionId, "profileDefinitionId");
  validateVersion(identity.releaseVersion);
  const row = await db
    .prepare(
      `SELECT release_version, worker_type_id, lifecycle_state, schema_version,
              engine_family, engine_compatibility_min,
              engine_compatibility_max_exclusive, payload_json, payload_digest,
              signature, signing_key_id, publisher, published_at, lifecycle_reason,
              revoked_at, created_by_user_id, updated_by_user_id, created_at, updated_at,
              (SELECT evidence_json FROM tool_profile_acceptance_evidence evidence
                WHERE evidence.profile_definition_id = release.profile_definition_id
                  AND evidence.release_version = release.release_version
                ORDER BY evidence.submitted_at DESC LIMIT 1)
                AS acceptance_evidence_json
         FROM tool_profile_releases AS release
        WHERE profile_definition_id = ?1 AND release_version = ?2`,
    )
    .bind(identity.profileDefinitionId, identity.releaseVersion)
    .first<{
      release_version: number;
      worker_type_id: string;
      lifecycle_state: ToolProfileLifecycle;
      schema_version: number;
      engine_family: string;
      engine_compatibility_min: string;
      engine_compatibility_max_exclusive: string;
      payload_json: string;
      payload_digest: string;
      signature: string | null;
      signing_key_id: string | null;
      publisher: string | null;
      published_at: string | null;
      lifecycle_reason: string | null;
      revoked_at: string | null;
      created_by_user_id: string | null;
      updated_by_user_id: string | null;
      created_at: string;
      updated_at: string;
      acceptance_evidence_json: string | null;
    }>();

  if (!row) {
    throw new ToolProfileRegistryError(
      404,
      "Tool Profile release was not found",
    );
  }

  return {
    releaseVersion: row.release_version,
    workerTypeId: row.worker_type_id,
    lifecycleState: row.lifecycle_state,
    schemaVersion: row.schema_version,
    engineFamily: row.engine_family,
    engineCompatibility: {
      min: row.engine_compatibility_min,
      maxExclusive: row.engine_compatibility_max_exclusive,
    },
    profile: JSON.parse(row.payload_json),
    payloadDigest: row.payload_digest,
    signature: row.signature,
    signingKeyId: row.signing_key_id,
    publisher: row.publisher,
    publishedAt: row.published_at,
    acceptanceEvidence: row.acceptance_evidence_json
      ? JSON.parse(row.acceptance_evidence_json)
      : null,
    lifecycleReason: row.lifecycle_reason,
    revokedAt: row.revoked_at,
    createdByUserId: row.created_by_user_id,
    updatedByUserId: row.updated_by_user_id,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

export async function listToolProfileChannelPointers(
  db: D1Database,
  profileDefinitionId?: string,
): Promise<{ channels: ToolProfileChannelPointerRecord[] }> {
  if (profileDefinitionId !== undefined) {
    validateId(profileDefinitionId, "profileDefinitionId");
  }
  const rows = await db
    .prepare(
      `SELECT profile_definition_id, channel, release_version, modified_by_user_id, updated_at
         FROM tool_profile_channel_pointers
        WHERE (?1 IS NULL OR profile_definition_id = ?1)
        ORDER BY profile_definition_id,
                 CASE channel WHEN 'stable' THEN 0 WHEN 'beta' THEN 1 ELSE 2 END`,
    )
    .bind(profileDefinitionId ?? null)
    .all<{
      profile_definition_id: string;
      channel: string;
      release_version: number;
      modified_by_user_id: string | null;
      updated_at: string;
    }>();
  return {
    channels: (rows.results ?? []).map((row) => ({
      profileDefinitionId: row.profile_definition_id,
      channel: row.channel as ToolProfileChannel,
      releaseVersion: row.release_version,
      modifiedByUserId: row.modified_by_user_id,
      updatedAt: row.updated_at,
    })),
  };
}

export async function rollbackToolProfileChannel(
  db: D1Database,
  args: {
    profileDefinitionId: string;
    channel: ToolProfileChannel;
    targetReleaseVersion: number;
    actorUserId: string;
    reason?: string;
  },
): Promise<{
  profileDefinitionId: string;
  channel: ToolProfileChannel;
  releaseVersion: number;
  previousReleaseVersion: number;
  action: "rolled_back";
}> {
  validateId(args.profileDefinitionId, "profileDefinitionId");
  validateVersion(args.targetReleaseVersion);
  if (!channelNames.has(args.channel)) {
    throw new ToolProfileRegistryError(400, "channel is invalid");
  }

  const current = await db
    .prepare(
      `SELECT release_version FROM tool_profile_channel_pointers
        WHERE profile_definition_id = ?1 AND channel = ?2`,
    )
    .bind(args.profileDefinitionId, args.channel)
    .first<{ release_version: number }>();

  if (!current) {
    throw new ToolProfileRegistryError(
      404,
      "Active channel pointer was not found",
    );
  }

  if (current.release_version === args.targetReleaseVersion) {
    throw new ToolProfileRegistryError(
      409,
      "Channel pointer is already at the requested release version",
    );
  }

  const targetRelease = await db
    .prepare(
      `SELECT release_version, lifecycle_state, published_at
         FROM tool_profile_releases
        WHERE profile_definition_id = ?1 AND release_version = ?2`,
    )
    .bind(args.profileDefinitionId, args.targetReleaseVersion)
    .first<{
      release_version: number;
      lifecycle_state: ToolProfileLifecycle;
      published_at: string | null;
    }>();

  if (!targetRelease) {
    throw new ToolProfileRegistryError(
      404,
      "Target Tool Profile release was not found",
    );
  }

  if (
    !targetRelease.published_at ||
    ["draft", "retired", "revoked"].includes(targetRelease.lifecycle_state)
  ) {
    throw new ToolProfileRegistryError(
      409,
      "Target release is not eligible for channel rollback",
    );
  }

  // The DB trigger on tool_profile_channel_pointers enforces release.lifecycle_state = channel.
  // If target release lifecycle state is not already the channel, verify transition validity.
  const allowedTransitions: Record<ToolProfileChannel, ToolProfileLifecycle[]> =
    {
      testing: ["testing"],
      beta: ["testing", "beta"],
      stable: ["testing", "beta", "stable"],
    };

  if (
    !allowedTransitions[args.channel].includes(targetRelease.lifecycle_state)
  ) {
    throw new ToolProfileRegistryError(
      409,
      `Target release in state '${targetRelease.lifecycle_state}' cannot enter channel '${args.channel}'`,
    );
  }

  const now = new Date().toISOString();
  const statements = [];

  if (targetRelease.lifecycle_state !== args.channel) {
    const lifecycleReason =
      args.reason?.trim() ||
      `Rolled back ${args.channel} from release ${current.release_version} to ${args.targetReleaseVersion}`;
    statements.push(
      db
        .prepare(
          `UPDATE tool_profile_releases
              SET lifecycle_state = ?1, updated_by_user_id = ?2,
                  lifecycle_reason = ?3, updated_at = ?4
            WHERE profile_definition_id = ?5 AND release_version = ?6
              AND published_at IS NOT NULL`,
        )
        .bind(
          args.channel,
          args.actorUserId,
          lifecycleReason,
          now,
          args.profileDefinitionId,
          args.targetReleaseVersion,
        ),
    );
  }

  statements.push(
    db
      .prepare(
        `UPDATE tool_profile_channel_pointers
            SET release_version = ?1, modified_by_user_id = ?2, updated_at = ?3
          WHERE profile_definition_id = ?4 AND channel = ?5`,
      )
      .bind(
        args.targetReleaseVersion,
        args.actorUserId,
        now,
        args.profileDefinitionId,
        args.channel,
      ),
  );

  const results = await db.batch(statements);
  if (!results.at(-1)?.meta.changes) {
    throw new ToolProfileRegistryError(
      409,
      "Tool Profile channel rollback was rejected",
    );
  }

  return {
    profileDefinitionId: args.profileDefinitionId,
    channel: args.channel,
    releaseVersion: args.targetReleaseVersion,
    previousReleaseVersion: current.release_version,
    action: "rolled_back",
  };
}

export async function submitToolProfileReleaseEvidence(
  db: D1Database,
  identity: ToolProfileReleaseIdentity,
  input: unknown,
  actorUserId: string,
): Promise<{
  id: string;
  status: "accepted";
  payloadDigest: string;
}> {
  validateId(identity.profileDefinitionId, "profileDefinitionId");
  validateVersion(identity.releaseVersion);

  const release = await db
    .prepare(
      `SELECT release_version, payload_digest, payload_json, worker_type_id,
              lifecycle_state, published_at
         FROM tool_profile_releases
        WHERE profile_definition_id = ?1 AND release_version = ?2`,
    )
    .bind(identity.profileDefinitionId, identity.releaseVersion)
    .first<{
      release_version: number;
      payload_digest: string;
      payload_json: string;
      worker_type_id: string;
      lifecycle_state: ToolProfileLifecycle;
      published_at: string | null;
    }>();

  if (!release) {
    throw new ToolProfileRegistryError(
      404,
      "Tool Profile release was not found",
    );
  }
  if (
    !release.published_at ||
    ["retired", "revoked"].includes(release.lifecycle_state)
  ) {
    throw new ToolProfileRegistryError(
      409,
      "Acceptance evidence can only be submitted for a published release",
    );
  }

  const profile = parseProfile(
    JSON.parse(release.payload_json),
    identity,
  ).profile;

  const acceptedEvidence = validateToolProfileAcceptanceEvidence(input, {
    identity,
    payloadDigest: release.payload_digest,
    profile,
  });

  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  await db
    .prepare(
      `INSERT INTO tool_profile_acceptance_evidence (
         id, profile_definition_id, release_version, payload_digest,
         engine_version, provider_tool_version, evidence_json,
         submitted_by_user_id, accepted_at, submitted_at
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)`,
    )
    .bind(
      id,
      identity.profileDefinitionId,
      identity.releaseVersion,
      release.payload_digest,
      acceptedEvidence.engineVersion,
      acceptedEvidence.providerToolVersion,
      JSON.stringify(acceptedEvidence),
      actorUserId,
      acceptedEvidence.acceptedAt,
      now,
    )
    .run();

  return {
    id,
    status: "accepted",
    payloadDigest: release.payload_digest,
  };
}

export async function listToolProfileReleaseEvidence(
  db: D1Database,
  identity: ToolProfileReleaseIdentity,
): Promise<{ evidence: ToolProfileAcceptanceEvidenceRecord[] }> {
  validateId(identity.profileDefinitionId, "profileDefinitionId");
  validateVersion(identity.releaseVersion);
  const rows = await db
    .prepare(
      `SELECT id, profile_definition_id, release_version, payload_digest,
              engine_version, provider_tool_version, evidence_json,
              submitted_by_user_id, accepted_at, submitted_at
         FROM tool_profile_acceptance_evidence
        WHERE profile_definition_id = ?1 AND release_version = ?2
        ORDER BY submitted_at DESC LIMIT 100`,
    )
    .bind(identity.profileDefinitionId, identity.releaseVersion)
    .all<{
      id: string;
      profile_definition_id: string;
      release_version: number;
      payload_digest: string;
      engine_version: string;
      provider_tool_version: string;
      evidence_json: string;
      submitted_by_user_id: string | null;
      accepted_at: string;
      submitted_at: string;
    }>();
  return {
    evidence: (rows.results ?? []).map((row) => ({
      id: row.id,
      profileDefinitionId: row.profile_definition_id,
      releaseVersion: row.release_version,
      payloadDigest: row.payload_digest,
      engineVersion: row.engine_version,
      providerToolVersion: row.provider_tool_version,
      evidence: JSON.parse(row.evidence_json),
      submittedByUserId: row.submitted_by_user_id,
      acceptedAt: row.accepted_at,
      submittedAt: row.submitted_at,
    })),
  };
}

export async function listToolProfileAudit(
  db: D1Database,
  profileDefinitionId?: string,
  limit: number = 100,
): Promise<{ events: ToolProfileAuditEvent[] }> {
  if (profileDefinitionId !== undefined) {
    validateId(profileDefinitionId, "profileDefinitionId");
  }
  const safeLimit = Math.max(1, Math.min(limit, 500));
  const rows = await db
    .prepare(
      `SELECT audit.id, audit.profile_definition_id, audit.release_version, audit.actor_user_id, audit.action,
              audit.previous_release_version, audit.channel, audit.from_state, audit.to_state, audit.reason,
              audit.details_json, audit.created_at, actor.display_name AS actor_display_name,
              worker.display_name AS worker_display_name
         FROM tool_profile_release_audit audit
         LEFT JOIN users actor ON actor.id = audit.actor_user_id
         LEFT JOIN tool_profile_definitions definition ON definition.profile_definition_id = audit.profile_definition_id
         LEFT JOIN worker_catalog worker ON worker.worker_type_id = definition.worker_type_id
        WHERE (?1 IS NULL OR audit.profile_definition_id = ?1)
        ORDER BY audit.created_at DESC, audit.id DESC LIMIT ?2`,
    )
    .bind(profileDefinitionId ?? null, safeLimit)
    .all<{
      id: string;
      profile_definition_id: string;
      release_version: number;
      actor_user_id: string | null;
      actor_display_name: string | null;
      worker_display_name: string | null;
      action: string;
      previous_release_version: number | null;
      channel: string | null;
      from_state: string | null;
      to_state: string | null;
      reason: string | null;
      details_json: string;
      created_at: string;
    }>();
  return {
    events: (rows.results ?? []).map((row) => ({
      id: row.id,
      profileDefinitionId: row.profile_definition_id,
      releaseVersion: row.release_version,
      actorUserId: row.actor_user_id,
      actorDisplayName: row.actor_display_name ?? null,
      workerDisplayName: row.worker_display_name ?? null,
      action: row.action,
      previousReleaseVersion: row.previous_release_version,
      channel: row.channel,
      fromState: row.from_state,
      toState: row.to_state,
      reason: row.reason,
      details: JSON.parse(row.details_json ?? "{}"),
      createdAt: row.created_at,
    })),
  };
}
