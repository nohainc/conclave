import { verifyEd25519ReleaseSignature } from "./release-trust.js";
import {
  ToolProfileRegistryError,
  channelNames,
  parseProfile,
  profileDigest,
  productCapabilities,
  toolProfileReleaseSigningMessage,
  validateId,
  validateToolProfileAcceptanceEvidence,
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
  validateToolProfileReleasePayload,
} from "./tool-profile-validation.js";
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
): Promise<{ payloadDigest: string }> {
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

export async function publishDraftToolProfileRelease(
  env: ToolProfileRegistryEnvironment,
  identity: ToolProfileReleaseIdentity,
  signature: string,
  signingKeyId: string,
  actorUserId: string,
): Promise<{ payloadDigest: string; publishedAt: string; status: "testing" }> {
  validateId(identity.profileDefinitionId, "profileDefinitionId");
  validateVersion(identity.releaseVersion);
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(signingKeyId)) {
    throw new ToolProfileRegistryError(400, "signingKeyId is invalid");
  }
  if (typeof signature !== "string" || signature.length > 256) {
    throw new ToolProfileRegistryError(400, "signature is invalid");
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
  const revokedKey = await env.CONCLAVE_DB.prepare(
    "SELECT key_id FROM release_signing_key_revocations WHERE key_id = ?1",
  )
    .bind(signingKeyId)
    .first<{ key_id: string }>();
  const publisher = env.CONCLAVE_RELEASE_PUBLISHER ?? "conclave";
  const signatureValid =
    !revokedKey &&
    (await verifyEd25519ReleaseSignature({
      trustKeysJson: env.CONCLAVE_RELEASE_TRUST_KEYS_JSON,
      publisher,
      signingKeyId,
      signature,
      message: toolProfileReleaseSigningMessage({
        publisher,
        signingKeyId,
        payloadDigest: actualDigest,
        profile: parsed.profile,
      }),
    }));
  if (!signatureValid) {
    throw new ToolProfileRegistryError(
      400,
      "Tool Profile signature is invalid or revoked",
    );
  }
  const publishedAt = new Date().toISOString();
  const result = await env.CONCLAVE_DB.prepare(
    `UPDATE tool_profile_releases
          SET lifecycle_state = 'testing', signature = ?1, signing_key_id = ?2,
              publisher = ?3, published_at = ?4, updated_by_user_id = ?5,
              lifecycle_reason = 'Signature verified', updated_at = ?4
        WHERE profile_definition_id = ?6 AND release_version = ?7
          AND lifecycle_state = 'draft' AND published_at IS NULL
          AND payload_digest = ?8`,
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
    )
    .run();
  if (!result.meta.changes) {
    throw new ToolProfileRegistryError(
      409,
      "Tool Profile draft changed before publication",
    );
  }
  return { payloadDigest: row.payload_digest, publishedAt, status: "testing" };
}

export async function promoteToolProfileRelease(
  db: D1Database,
  identity: ToolProfileReleaseIdentity,
  channel: ToolProfileChannel,
  actorUserId: string,
  acceptanceEvidence?: unknown,
): Promise<{
  channel: ToolProfileChannel;
  releaseVersion: number;
  action: "promoted" | "rolled_back";
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
  let acceptedEvidence: ToolProfileAcceptanceEvidence | null = null;
  if (channel === "stable") {
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
    acceptedEvidence = validateToolProfileAcceptanceEvidence(
      acceptanceEvidence,
      {
        identity,
        payloadDigest: row.payload_digest,
        profile,
      },
    );
  } else if (acceptanceEvidence !== undefined) {
    throw new ToolProfileRegistryError(
      400,
      "Acceptance evidence is only accepted for stable promotion",
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
    if (acceptedEvidence) {
      await db
        .prepare(
          `INSERT OR IGNORE INTO tool_profile_acceptance_evidence (
             id, profile_definition_id, release_version, payload_digest,
             engine_version, provider_tool_version, evidence_json,
             submitted_by_user_id, accepted_at, submitted_at
           ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)`,
        )
        .bind(
          crypto.randomUUID(),
          identity.profileDefinitionId,
          identity.releaseVersion,
          row.payload_digest,
          acceptedEvidence.engineVersion,
          acceptedEvidence.providerToolVersion,
          JSON.stringify(acceptedEvidence),
          actorUserId,
          acceptedEvidence.acceptedAt,
          new Date().toISOString(),
        )
        .run();
    }
    return {
      channel,
      releaseVersion: identity.releaseVersion,
      action: "promoted",
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
  if (acceptedEvidence) {
    statements.push(
      db
        .prepare(
          `INSERT OR IGNORE INTO tool_profile_acceptance_evidence (
             id, profile_definition_id, release_version, payload_digest,
             engine_version, provider_tool_version, evidence_json,
             submitted_by_user_id, accepted_at, submitted_at
           ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)`,
        )
        .bind(
          crypto.randomUUID(),
          identity.profileDefinitionId,
          identity.releaseVersion,
          row.payload_digest,
          acceptedEvidence.engineVersion,
          acceptedEvidence.providerToolVersion,
          JSON.stringify(acceptedEvidence),
          actorUserId,
          acceptedEvidence.acceptedAt,
          now,
        ),
    );
  }
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
          `${action} to ${channel}`,
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
  const results = await db.batch(statements);
  if (!results.at(-1)?.meta.changes) {
    throw new ToolProfileRegistryError(
      409,
      "Tool Profile channel promotion was rejected",
    );
  }
  return { channel, releaseVersion: identity.releaseVersion, action };
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
  workerTypeId?: string,
  channel: ToolProfileChannel = "stable",
): Promise<{
  workers: Record<string, unknown>[];
  profiles: Record<string, unknown>[];
}> {
  if (workerTypeId !== undefined) validateId(workerTypeId, "workerTypeId");
  if (channel !== undefined && !channelNames.has(channel)) {
    throw new ToolProfileRegistryError(400, "channel is invalid");
  }
  if (workerTypeId === undefined) {
    return {
      workers: await resolveLogicalWorkerCatalog(
        db,
        undefined,
        channel ?? "stable",
      ),
      profiles: [],
    };
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
    .bind(workerTypeId ?? null, channel ?? null)
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
    workers: await resolveLogicalWorkerCatalog(db, workerTypeId, channel),
    profiles: (rows.results ?? []).map((row) => ({
      profileDefinitionId: row.profile_definition_id,
      workerTypeId: row.worker_type_id,
      displayName: row.display_name,
      providerToolName: row.provider_tool_name,
      channel: row.channel,
      releaseVersion: row.release_version,
      profile: JSON.parse(row.payload_json),
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
    })),
  };
}

/** Lists active visible logical Workers independently of release availability. */
export async function resolveLogicalWorkerCatalog(
  db: D1Database,
  workerTypeId?: string,
  channel: ToolProfileChannel = "stable",
): Promise<Record<string, unknown>[]> {
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
    return {
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
    };
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
