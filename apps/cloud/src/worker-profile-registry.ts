import {
  canonicalReleaseJson,
  signEd25519ReleaseMessage,
  verifyEd25519ReleaseSignature,
} from "./release-trust.js";
import type { ToolProfileV1 } from "@conclave/tool-profile";
import {
  ToolProfileRegistryError,
  parseProfile,
  profileDigest,
  workerProfileSigningMessage,
  validateId,
  validateWorkerProfilePublicationEvidence,
  validateProviderCompatibilityForPublication,
  type ToolProfileRegistryEnvironment,
  type WorkerProfilePublicationEvidence,
} from "./tool-profile-validation.js";

export {
  ToolProfileRegistryError,
  validateWorkerProfilePublicationEvidence,
  validateProviderCompatibilityForPublication,
} from "./tool-profile-validation.js";
export type {
  ToolProfileRegistryEnvironment,
  WorkerProfilePublicationEvidence,
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

const signingPreflightMessage =
  "conclave-tool-profile-signing-preflight-v1\\nconclave";

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

// V9 Worker Profile registry
// ---------------------------------------------------------------------------

export interface WorkerProfileSummary {
  workerTypeId: string;
  displayName: string;
  description: string;
  profileDefinitionId: string | null;
  providerToolName: string | null;
  lifecycleState: string;
  engineFamily: string;
  visibilityState: string;
  sortOrder: number;
  currentRevision: number | null;
  currentDigest: string | null;
  currentUpdatedAt: string | null;
}

export interface WorkerProfileSnapshot {
  workerTypeId: string;
  schemaVersion: number;
  profile: ToolProfileV1;
  revision: number;
  digest: string;
  signature: string;
  signingKeyId: string;
  publisher: string;
  updatedByUserId: string | null;
  updatedAt: string;
  verified: boolean;
}

export interface WorkerProfileHistorySnapshot extends WorkerProfileSnapshot {
  actorUserId: string | null;
  publishedAt: string;
  restorationReason: string | null;
}

interface CurrentWorkerProfileRow {
  worker_type_id: string;
  schema_version: number;
  profile_json: string;
  revision: number;
  digest: string;
  signature: string;
  signing_key_id: string;
  updated_by_user_id: string | null;
  updated_at: string;
}

function requireDigest(value: unknown, label = "candidateDigest"): string {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value)) {
    throw new ToolProfileRegistryError(400, `${label} is invalid`);
  }
  return value;
}

function requireRevision(value: unknown, label: string): number {
  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < 0 ||
    value > 2_147_483_647
  ) {
    throw new ToolProfileRegistryError(400, `${label} is invalid`);
  }
  return value;
}

function parseCurrentWorkerProfile(
  row: CurrentWorkerProfileRow,
): ToolProfileV1 {
  let input: unknown;
  try {
    input = JSON.parse(row.profile_json);
  } catch {
    throw new ToolProfileRegistryError(
      409,
      "The current Worker Profile contains invalid JSON",
    );
  }
  const parsed = parseProfile(input, undefined);
  if (
    parsed.profile.logicalWorkerTypeId !== row.worker_type_id ||
    parsed.profile.schemaVersion !== row.schema_version
  ) {
    throw new ToolProfileRegistryError(
      409,
      "The current Worker Profile identity is inconsistent with its registry row",
    );
  }
  return parsed.profile;
}

async function verifyWorkerProfileSnapshot(
  env: ToolProfileRegistryEnvironment,
  row: CurrentWorkerProfileRow,
  profile: ToolProfileV1,
): Promise<boolean> {
  const actualDigest = await profileDigest(canonicalProfilePayload(profile));
  if (actualDigest !== row.digest) return false;
  const publisher = env.CONCLAVE_RELEASE_PUBLISHER?.trim();
  if (!publisher) return false;
  const v9Verified = await verifyEd25519ReleaseSignature({
    trustKeysJson: env.CONCLAVE_RELEASE_TRUST_KEYS_JSON,
    publisher,
    signingKeyId: row.signing_key_id,
    signature: row.signature,
    message: workerProfileSigningMessage({
      publisher,
      signingKeyId: row.signing_key_id,
      workerTypeId: row.worker_type_id,
      revision: row.revision,
      schemaVersion: row.schema_version,
      payloadDigest: row.digest,
    }),
  });
  return v9Verified;
}

function canonicalProfilePayload(profile: ToolProfileV1): string {
  return canonicalReleaseJson(profile);
}

export async function listWorkerProfiles(
  db: D1Database,
): Promise<{ workers: WorkerProfileSummary[] }> {
  const rows = await db
    .prepare(
      `SELECT worker.worker_type_id, worker.display_name, worker.description,
              worker.lifecycle_state, worker.engine_family,
              worker.visibility_state, worker.sort_order,
              COALESCE(worker.profile_definition_id,
                json_extract(current_profile.profile_json,
                  '$.profileDefinitionId')) AS profile_definition_id,
              COALESCE(worker.provider_tool_name,
                json_extract(current_profile.profile_json,
                  '$.providerTool.name')) AS provider_tool_name,
              current_profile.revision AS current_revision,
              current_profile.digest AS current_digest,
              current_profile.updated_at AS current_updated_at
         FROM worker_catalog worker
         LEFT JOIN worker_profiles current_profile
           ON current_profile.worker_type_id = worker.worker_type_id
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
      sort_order: number;
      profile_definition_id: string | null;
      provider_tool_name: string | null;
      current_revision: number | null;
      current_digest: string | null;
      current_updated_at: string | null;
    }>();
  return {
    workers: (rows.results ?? []).map((row) => ({
      workerTypeId: row.worker_type_id,
      displayName: row.display_name,
      description: row.description,
      profileDefinitionId:
        row.profile_definition_id == null
          ? null
          : String(row.profile_definition_id),
      providerToolName:
        row.provider_tool_name == null ? null : String(row.provider_tool_name),
      lifecycleState: row.lifecycle_state,
      engineFamily: row.engine_family,
      visibilityState: row.visibility_state,
      sortOrder: row.sort_order,
      currentRevision: row.current_revision,
      currentDigest: row.current_digest,
      currentUpdatedAt: row.current_updated_at,
    })),
  };
}

async function loadCurrentWorkerProfileRow(
  db: D1Database,
  workerTypeId: string,
): Promise<CurrentWorkerProfileRow | null> {
  return db
    .prepare(
      `SELECT worker_type_id, schema_version, profile_json, revision,
              digest, signature, signing_key_id, updated_by_user_id, updated_at
         FROM worker_profiles
        WHERE worker_type_id = ?1`,
    )
    .bind(workerTypeId)
    .first<CurrentWorkerProfileRow>();
}

async function requireWorkerCatalogRow(
  db: D1Database,
  workerTypeId: string,
): Promise<void> {
  const row = await db
    .prepare(
      "SELECT worker_type_id FROM worker_catalog WHERE worker_type_id = ?1",
    )
    .bind(workerTypeId)
    .first<{ worker_type_id: string }>();
  if (!row) throw new ToolProfileRegistryError(404, "Worker was not found");
}

export async function getCurrentWorkerProfile(
  env: ToolProfileRegistryEnvironment,
  workerTypeId: string,
): Promise<WorkerProfileSnapshot> {
  validateId(workerTypeId, "workerTypeId");
  await requireWorkerCatalogRow(env.CONCLAVE_DB, workerTypeId);
  const row = await loadCurrentWorkerProfileRow(env.CONCLAVE_DB, workerTypeId);
  if (!row) {
    throw new ToolProfileRegistryError(
      404,
      "The Worker does not have a published Profile",
    );
  }
  const profile = parseCurrentWorkerProfile(row);
  const verified = await verifyWorkerProfileSnapshot(env, row, profile);
  if (!verified) {
    throw new ToolProfileRegistryError(
      409,
      "The current Worker Profile failed digest or signature verification",
    );
  }
  return {
    workerTypeId: row.worker_type_id,
    schemaVersion: row.schema_version,
    profile,
    revision: row.revision,
    digest: row.digest,
    signature: row.signature,
    signingKeyId: row.signing_key_id,
    publisher: env.CONCLAVE_RELEASE_PUBLISHER?.trim() ?? "",
    updatedByUserId: row.updated_by_user_id,
    updatedAt: row.updated_at,
    verified,
  };
}

export async function listWorkerProfileHistory(
  env: ToolProfileRegistryEnvironment,
  workerTypeId: string,
): Promise<{ history: WorkerProfileHistorySnapshot[] }> {
  validateId(workerTypeId, "workerTypeId");
  await requireWorkerCatalogRow(env.CONCLAVE_DB, workerTypeId);
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT worker_type_id, schema_version, profile_json, revision,
              digest, signature, signing_key_id, actor_user_id,
              published_at, restoration_reason
         FROM worker_profile_history
        WHERE worker_type_id = ?1
        ORDER BY revision DESC
        LIMIT 256`,
  )
    .bind(workerTypeId)
    .all<{
      worker_type_id: string;
      schema_version: number;
      profile_json: string;
      revision: number;
      digest: string;
      signature: string;
      signing_key_id: string;
      actor_user_id: string | null;
      published_at: string;
      restoration_reason: string | null;
    }>();
  return {
    history: await Promise.all(
      (rows.results ?? []).map(async (row) => {
        const profile = parseCurrentWorkerProfile({
          worker_type_id: row.worker_type_id,
          schema_version: row.schema_version,
          profile_json: row.profile_json,
          revision: row.revision,
          digest: row.digest,
          signature: row.signature,
          signing_key_id: row.signing_key_id,
          updated_by_user_id: row.actor_user_id,
          updated_at: row.published_at,
        });
        const verified = await verifyWorkerProfileSnapshot(
          env,
          {
            worker_type_id: row.worker_type_id,
            schema_version: row.schema_version,
            profile_json: row.profile_json,
            revision: row.revision,
            digest: row.digest,
            signature: row.signature,
            signing_key_id: row.signing_key_id,
            updated_by_user_id: row.actor_user_id,
            updated_at: row.published_at,
          },
          profile,
        );
        return {
          workerTypeId: row.worker_type_id,
          schemaVersion: row.schema_version,
          profile,
          revision: row.revision,
          digest: row.digest,
          signature: row.signature,
          signingKeyId: row.signing_key_id,
          publisher: env.CONCLAVE_RELEASE_PUBLISHER?.trim() ?? "",
          updatedByUserId: row.actor_user_id,
          updatedAt: row.published_at,
          verified,
          actorUserId: row.actor_user_id,
          publishedAt: row.published_at,
          restorationReason: row.restoration_reason,
        };
      }),
    ),
  };
}

export async function validateWorkerProfileCandidate(
  workerTypeId: string,
  candidate: unknown,
  candidateDigest?: unknown,
  evidence?: unknown,
): Promise<{
  profile: ToolProfileV1;
  canonicalJson: string;
  digest: string;
  evidence: WorkerProfilePublicationEvidence | null;
}> {
  validateId(workerTypeId, "workerTypeId");
  const parsed = parseProfile(candidate);
  if (parsed.profile.logicalWorkerTypeId !== workerTypeId) {
    throw new ToolProfileRegistryError(
      400,
      "Profile logical Worker does not match the requested Worker",
    );
  }
  validateProviderCompatibilityForPublication(parsed.profile);
  const digest = await profileDigest(parsed.payload);
  if (
    candidateDigest !== undefined &&
    requireDigest(candidateDigest) !== digest
  ) {
    throw new ToolProfileRegistryError(
      409,
      "candidateDigest does not match the canonical Profile JSON",
    );
  }
  const validatedEvidence =
    evidence === undefined
      ? null
      : validateWorkerProfilePublicationEvidence(evidence, {
          workerTypeId,
          candidateDigest: digest,
          profile: parsed.profile,
        });
  return {
    profile: parsed.profile,
    canonicalJson: parsed.payload,
    digest,
    evidence: validatedEvidence,
  };
}

async function persistWorkerProfileSnapshot(args: {
  env: ToolProfileRegistryEnvironment;
  workerTypeId: string;
  expectedRevision: number;
  current: CurrentWorkerProfileRow | null;
  profile: ToolProfileV1;
  canonicalJson: string;
  digest: string;
  signature: string;
  signingKeyId: string;
  actorUserId: string;
  updatedAt: string;
  restorationReason: string | null;
}): Promise<number> {
  const nextRevision = (args.current?.revision ?? 0) + 1;
  if (nextRevision > 2_147_483_647) {
    throw new ToolProfileRegistryError(
      409,
      "Worker Profile revision limit reached",
    );
  }
  const db = args.env.CONCLAVE_DB;
  if (!args.current) {
    if (args.expectedRevision !== 0) {
      throw new ToolProfileRegistryError(
        409,
        "Worker Profile revision is stale",
      );
    }
    const result = await db
      .prepare(
        `INSERT INTO worker_profiles
           (worker_type_id, schema_version, profile_json, revision, digest,
            signature, signing_key_id, updated_by_user_id, updated_at)
         VALUES (?1, ?2, ?3, 1, ?4, ?5, ?6, ?7, ?8)
         ON CONFLICT(worker_type_id) DO NOTHING`,
      )
      .bind(
        args.workerTypeId,
        args.profile.schemaVersion,
        args.canonicalJson,
        args.digest,
        args.signature,
        args.signingKeyId,
        args.actorUserId,
        args.updatedAt,
      )
      .run();
    if (Number(result.meta?.changes ?? 0) !== 1) {
      throw new ToolProfileRegistryError(
        409,
        "Worker Profile revision is stale",
      );
    }
    return 1;
  }

  const results = await db.batch([
    db
      .prepare(
        `INSERT INTO worker_profile_history
           (worker_type_id, revision, schema_version, profile_json, digest,
            signature, signing_key_id, actor_user_id, published_at,
            restoration_reason)
         SELECT worker_type_id, revision, schema_version, profile_json, digest,
                signature, signing_key_id, updated_by_user_id, updated_at, ?4
           FROM worker_profiles
          WHERE worker_type_id = ?1 AND revision = ?2 AND digest = ?3`,
      )
      .bind(
        args.workerTypeId,
        args.expectedRevision,
        args.current.digest,
        args.restorationReason,
      ),
    db
      .prepare(
        `UPDATE worker_profiles
            SET schema_version = ?1, profile_json = ?2, revision = ?3,
                digest = ?4, signature = ?5, signing_key_id = ?6,
                updated_by_user_id = ?7, updated_at = ?8
          WHERE worker_type_id = ?9 AND revision = ?10 AND digest = ?11`,
      )
      .bind(
        args.profile.schemaVersion,
        args.canonicalJson,
        nextRevision,
        args.digest,
        args.signature,
        args.signingKeyId,
        args.actorUserId,
        args.updatedAt,
        args.workerTypeId,
        args.expectedRevision,
        args.current.digest,
      ),
  ]);
  if (Number(results[1]?.meta?.changes ?? 0) !== 1) {
    throw new ToolProfileRegistryError(409, "Worker Profile revision is stale");
  }
  return nextRevision;
}

export async function publishWorkerProfile(args: {
  env: ToolProfileRegistryEnvironment;
  workerTypeId: string;
  expectedRevision: number;
  candidate: unknown;
  candidateDigest: unknown;
  evidence: unknown;
  actorUserId: string;
}): Promise<WorkerProfileSnapshot> {
  validateId(args.workerTypeId, "workerTypeId");
  await requireWorkerCatalogRow(args.env.CONCLAVE_DB, args.workerTypeId);
  const candidateDigest = requireDigest(args.candidateDigest);
  const validated = await validateWorkerProfileCandidate(
    args.workerTypeId,
    args.candidate,
    candidateDigest,
    args.evidence,
  );
  if (validated.evidence === null) {
    throw new ToolProfileRegistryError(
      409,
      "Publication requires complete evidence for this exact Profile candidate",
    );
  }
  requireRevision(args.expectedRevision, "expectedRevision");
  const current = await loadCurrentWorkerProfileRow(
    args.env.CONCLAVE_DB,
    args.workerTypeId,
  );
  if ((current?.revision ?? 0) !== args.expectedRevision) {
    throw new ToolProfileRegistryError(409, "Worker Profile revision is stale");
  }
  const preflight = await toolProfileSigningPreflight(args.env);
  if (!preflight.ready) {
    throw new ToolProfileRegistryError(
      503,
      `Worker Profile signing is not ready (${preflight.issues.join(", ")})`,
    );
  }
  const publisher = preflight.publisher!;
  const signingKeyId = preflight.signingKeyId!;
  const revision = (current?.revision ?? 0) + 1;
  const signature = signEd25519ReleaseMessage({
    privateKeyBase64OrPem: args.env.CONCLAVE_RELEASE_PRIVATE_KEY!,
    message: workerProfileSigningMessage({
      publisher,
      signingKeyId,
      workerTypeId: args.workerTypeId,
      revision,
      schemaVersion: validated.profile.schemaVersion,
      payloadDigest: validated.digest,
    }),
  });
  const signatureValid = await verifyEd25519ReleaseSignature({
    trustKeysJson: args.env.CONCLAVE_RELEASE_TRUST_KEYS_JSON,
    publisher,
    signingKeyId,
    signature,
    message: workerProfileSigningMessage({
      publisher,
      signingKeyId,
      workerTypeId: args.workerTypeId,
      revision,
      schemaVersion: validated.profile.schemaVersion,
      payloadDigest: validated.digest,
    }),
  });
  if (!signatureValid) {
    throw new ToolProfileRegistryError(
      500,
      "Cloud signing boundary failed to produce a valid Worker Profile signature",
    );
  }
  await persistWorkerProfileSnapshot({
    env: args.env,
    workerTypeId: args.workerTypeId,
    expectedRevision: args.expectedRevision,
    current,
    profile: validated.profile,
    canonicalJson: validated.canonicalJson,
    digest: validated.digest,
    signature,
    signingKeyId,
    actorUserId: args.actorUserId,
    updatedAt: new Date().toISOString(),
    restorationReason: null,
  });
  return getCurrentWorkerProfile(args.env, args.workerTypeId);
}

export async function restoreWorkerProfile(args: {
  env: ToolProfileRegistryEnvironment;
  workerTypeId: string;
  expectedRevision: number;
  targetRevision: number;
  restorationReason: string;
  actorUserId: string;
}): Promise<WorkerProfileSnapshot> {
  validateId(args.workerTypeId, "workerTypeId");
  requireRevision(args.expectedRevision, "expectedRevision");
  requireRevision(args.targetRevision, "targetRevision");
  if (!args.restorationReason.trim() || args.restorationReason.length > 512) {
    throw new ToolProfileRegistryError(400, "restorationReason is invalid");
  }
  await requireWorkerCatalogRow(args.env.CONCLAVE_DB, args.workerTypeId);
  const current = await loadCurrentWorkerProfileRow(
    args.env.CONCLAVE_DB,
    args.workerTypeId,
  );
  if (!current || current.revision !== args.expectedRevision) {
    throw new ToolProfileRegistryError(409, "Worker Profile revision is stale");
  }
  const history = await args.env.CONCLAVE_DB.prepare(
    `SELECT worker_type_id, schema_version, profile_json, revision,
              digest, signature, signing_key_id, actor_user_id,
              published_at AS updated_at
         FROM worker_profile_history
        WHERE worker_type_id = ?1 AND revision = ?2`,
  )
    .bind(args.workerTypeId, args.targetRevision)
    .first<CurrentWorkerProfileRow>();
  if (!history)
    throw new ToolProfileRegistryError(404, "Profile revision was not found");
  const profile = parseCurrentWorkerProfile(history);
  if (!(await verifyWorkerProfileSnapshot(args.env, history, profile))) {
    throw new ToolProfileRegistryError(
      409,
      "The historical Worker Profile failed digest or signature verification",
    );
  }
  const validated = await validateWorkerProfileCandidate(
    args.workerTypeId,
    profile,
    history.digest,
  );
  const preflight = await toolProfileSigningPreflight(args.env);
  if (!preflight.ready) {
    throw new ToolProfileRegistryError(
      503,
      `Worker Profile signing is not ready (${preflight.issues.join(", ")})`,
    );
  }
  const publisher = preflight.publisher!;
  const signingKeyId = preflight.signingKeyId!;
  const nextRevision = current.revision + 1;
  const signature = signEd25519ReleaseMessage({
    privateKeyBase64OrPem: args.env.CONCLAVE_RELEASE_PRIVATE_KEY!,
    message: workerProfileSigningMessage({
      publisher,
      signingKeyId,
      workerTypeId: args.workerTypeId,
      revision: nextRevision,
      schemaVersion: validated.profile.schemaVersion,
      payloadDigest: validated.digest,
    }),
  });
  const signatureValid = await verifyEd25519ReleaseSignature({
    trustKeysJson: args.env.CONCLAVE_RELEASE_TRUST_KEYS_JSON,
    publisher,
    signingKeyId,
    signature,
    message: workerProfileSigningMessage({
      publisher,
      signingKeyId,
      workerTypeId: args.workerTypeId,
      revision: nextRevision,
      schemaVersion: validated.profile.schemaVersion,
      payloadDigest: validated.digest,
    }),
  });
  if (!signatureValid) {
    throw new ToolProfileRegistryError(
      500,
      "Cloud signing boundary failed to produce a valid Worker Profile signature",
    );
  }
  await persistWorkerProfileSnapshot({
    env: args.env,
    workerTypeId: args.workerTypeId,
    expectedRevision: args.expectedRevision,
    current,
    profile: validated.profile,
    canonicalJson: validated.canonicalJson,
    digest: validated.digest,
    signature,
    signingKeyId,
    actorUserId: args.actorUserId,
    updatedAt: new Date().toISOString(),
    restorationReason: args.restorationReason,
  });
  return getCurrentWorkerProfile(args.env, args.workerTypeId);
}
