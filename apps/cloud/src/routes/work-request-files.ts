import { computePackageDigest } from "@conclave/security";
import {
  HttpError,
  artifactName,
  authorizeThreadAccess,
  json,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";

/** Base64 JPEG thumbnail budget; AX enforces the same value. */
const MAX_PREVIEW_IMAGE_CHARS = 32000;

/** Per-file and per-request limits; `USER_STORAGE_QUOTA_BYTES` caps the total. */
export const MAX_WORK_REQUEST_FILE_BYTES = 10 * 1024 * 1024;
export const MAX_WORK_REQUEST_FILES = 10;
/** Total bytes one user may keep in uploaded files (see `user_files`). */
export const USER_STORAGE_QUOTA_BYTES = 1024 * 1024 * 1024;

/** Bytes and count of the user's uploaded files that still exist. */
export async function userStorageUsage(
  env: SecurityEnv,
  userId: string,
): Promise<{ usedBytes: number; fileCount: number; quotaBytes: number }> {
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT COALESCE(SUM(size_bytes), 0) AS usedBytes, COUNT(*) AS fileCount
      FROM user_files WHERE user_id = ?1`,
  )
    .bind(userId)
    .first<{ usedBytes: number; fileCount: number }>();
  return {
    usedBytes: Number(row?.usedBytes ?? 0),
    fileCount: Number(row?.fileCount ?? 0),
    quotaBytes: USER_STORAGE_QUOTA_BYTES,
  };
}

const FILE_ID_PATTERN =
  /^wrf-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * A display name for a submitted file: path separators and control
 * characters become `_`; everything else (spaces, punctuation, Unicode) is
 * kept. Bytes are always stored under the generated file id, never this name.
 */
export function workRequestFileName(value: unknown): string {
  return typeof value === "string"
    ? // eslint-disable-next-line no-control-regex -- Strip control characters.
      value.replace(/[\\/\u0000-\u001f\u007f]/g, "_").slice(0, 255) ||
        "Attachment"
    : "Attachment";
}

export function isWorkRequestFileId(value: unknown): value is string {
  return typeof value === "string" && FILE_ID_PATTERN.test(value);
}

export function workRequestFileKey(fileId: string): string {
  return `work-request-inputs/${fileId}`;
}

/**
 * Stores one Work Request input file in R2. The object is bound to the
 * uploading user and Thread; Work Request creation verifies that binding
 * before it accepts the returned `fileId`.
 */
export async function handleUploadWorkRequestFile(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { context, spaceId } = await authorizeThreadAccess(
    request,
    env,
    threadId,
    new URL(request.url).searchParams.get("purpose") === "discussion"
      ? "discuss"
      : "execute",
    accessContext,
  );
  const upload = await readWorkRequestFileUpload(request);
  const url = new URL(request.url);
  const name = artifactName(
    url.searchParams.get("name") ?? request.headers.get("x-file-name"),
  );
  const fileId = `wrf-${crypto.randomUUID()}`;
  const { digest, mediaType, body } = {
    ...upload,
    ...(await storeWorkRequestFile(env, {
      fileId,
      threadId,
      spaceId: spaceId ?? null,
      userId: context.userId,
      name,
      upload,
    })),
  };
  return json(
    {
      file: {
        fileId,
        name,
        mediaType,
        sizeBytes: body.byteLength,
        contentDigest: digest,
      },
    },
    { status: 201 },
  );
}

export interface WorkRequestFileUpload {
  readonly body: ArrayBuffer;
  readonly mediaType: string;
  readonly previewImage?: string;
}

/** Reads one bounded upload body (raw bytes or multipart with a preview). */
export async function readWorkRequestFileUpload(
  request: Request,
): Promise<WorkRequestFileUpload> {
  const declared = request.headers.get("content-length");
  if (declared !== null) {
    const length = Number(declared);
    if (
      !Number.isSafeInteger(length) ||
      length > MAX_WORK_REQUEST_FILE_BYTES + 24 * 1024
    )
      throw new HttpError(413, "File exceeds the 10 MB limit");
  }
  let body: ArrayBuffer;
  let submittedType: string | null = null;
  let previewImage: string | undefined;
  if (request.headers.get("content-type")?.startsWith("multipart/form-data")) {
    const form = await request.formData();
    const file = form.get("file");
    if (!file || typeof file === "string")
      throw new HttpError(400, "File content is required");
    body = await file.arrayBuffer();
    const type = form.get("mediaType");
    submittedType = typeof type === "string" ? type : null;
    const preview = form.get("previewImage");
    if (typeof preview === "string") {
      if (
        preview.length > MAX_PREVIEW_IMAGE_CHARS ||
        !/^[A-Za-z0-9+/]*={0,2}$/.test(preview) ||
        !preview.startsWith("/9j/")
      )
        throw new HttpError(400, "Invalid image preview");
      previewImage = preview;
    }
  } else {
    body = await request.arrayBuffer();
  }
  if (body.byteLength > MAX_WORK_REQUEST_FILE_BYTES)
    throw new HttpError(413, "File exceeds the 10 MB limit");
  const mediaType =
    (submittedType ?? request.headers.get("content-type"))
      ?.split(";", 1)[0]
      ?.trim()
      .slice(0, 128) || "application/octet-stream";
  return { body, mediaType, ...(previewImage ? { previewImage } : {}) };
}

/**
 * Writes uploaded bytes to R2 under [fileId], bound to the uploading user and
 * Thread, and records them for My Files and the storage quota. Rewriting the
 * same [fileId] (a restarted upload) replaces the object and its accounting.
 */
export async function storeWorkRequestFile(
  env: SecurityEnv,
  input: {
    fileId: string;
    threadId: string;
    spaceId: string | null;
    userId: string;
    name: string;
    upload: WorkRequestFileUpload;
    workRequestId?: string;
  },
): Promise<{ digest: string; previewText?: string; previewImage?: string }> {
  const bucket = env.CONCLAVE_ARTIFACTS;
  if (!bucket) throw new HttpError(503, "File storage is not configured");
  const { body, mediaType, previewImage } = input.upload;
  // Best effort under concurrency: parallel uploads may each pass this check
  // and overshoot the quota by at most one batch.
  const usage = await userStorageUsage(env, input.userId);
  if (usage.usedBytes + body.byteLength > usage.quotaBytes)
    throw new HttpError(
      413,
      "Storage quota exceeded. Delete files in My Files to free space",
    );
  const previewText = fileTextPreview(input.name, mediaType, body);
  const digest = await computePackageDigest(body);
  await bucket.put(workRequestFileKey(input.fileId), body, {
    httpMetadata: { contentType: mediaType },
    customMetadata: {
      threadId: input.threadId,
      userId: input.userId,
      name: input.name,
      digest,
      ...(input.workRequestId ? { workRequestId: input.workRequestId } : {}),
      ...(previewText || previewImage ? { hasPreview: "1" } : {}),
    },
  });
  if (previewText || previewImage)
    await bucket.put(
      `${workRequestFileKey(input.fileId)}/preview`,
      JSON.stringify({ previewText, previewImage }),
      {
        httpMetadata: { contentType: "application/json" },
      },
    );
  await env.CONCLAVE_DB.prepare(
    `INSERT OR REPLACE INTO user_files
      (id, user_id, thread_id, space_id, name, media_type, size_bytes, created_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
  )
    .bind(
      input.fileId,
      input.userId,
      input.threadId,
      input.spaceId,
      input.name,
      mediaType,
      body.byteLength,
      new Date().toISOString(),
    )
    .run();
  return {
    digest,
    ...(previewText ? { previewText } : {}),
    ...(previewImage ? { previewImage } : {}),
  };
}

/** Confirms an uploaded file belongs to this user and Thread and matches the claim. */
export async function verifyWorkRequestFile(
  env: SecurityEnv,
  fileId: string,
  threadId: string,
  userId: string,
  sizeBytes: unknown,
): Promise<{ digest: string; previewText?: string; previewImage?: string }> {
  const object = await env.CONCLAVE_ARTIFACTS?.head(workRequestFileKey(fileId));
  const meta = object?.customMetadata;
  if (
    !object ||
    meta?.threadId !== threadId ||
    meta?.userId !== userId ||
    object.size > MAX_WORK_REQUEST_FILE_BYTES ||
    object.size !== sizeBytes
  )
    throw new HttpError(400, "Attached file was not found or does not match");
  const preview =
    meta.hasPreview === "1"
      ? await env.CONCLAVE_ARTIFACTS?.get(
          `${workRequestFileKey(fileId)}/preview`,
        )
      : null;
  const display = preview
    ? await preview.json<{ previewText?: string; previewImage?: string }>()
    : {};
  return {
    ...display,
    digest: meta.digest ?? "",
  };
}

/** Metadata and bounded display previews for authenticated Work history. */
export function workRequestFileMetadata(input: Record<string, unknown>) {
  if (!Array.isArray(input.attachments)) return [];
  return input.attachments.flatMap((value: unknown) => {
    if (!value || typeof value !== "object") return [];
    const file = value as Record<string, unknown>;
    if (file.kind !== "file") return [];
    return [
      {
        kind: "file" as const,
        ...(isWorkRequestFileId(file.fileId) ? { fileId: file.fileId } : {}),
        name: typeof file.name === "string" ? file.name : "Attachment",
        sizeBytes: typeof file.sizeBytes === "number" ? file.sizeBytes : 0,
        ...(typeof file.previewImage === "string"
          ? { previewImage: file.previewImage }
          : {}),
        ...(typeof file.previewText === "string"
          ? { previewText: file.previewText.slice(0, 1200) }
          : {}),
      },
    ];
  });
}

/** Plain text only; attached markup is never executed by the client. */
export function fileTextPreview(
  name: string,
  mediaType: string,
  body: ArrayBuffer,
): string | undefined {
  if (
    !mediaType.startsWith("text/") &&
    !/\.(txt|md|csv|json|yaml|yml|dart|ts|js|py|log)$/i.test(name)
  )
    return undefined;
  return (
    new TextDecoder()
      .decode(body.slice(0, 1200))
      // eslint-disable-next-line no-control-regex -- Remove null bytes from decoded text preview.
      .replace(/\u0000/g, "")
      .slice(0, 1200)
  );
}

/** Uses verified object metadata, never client-authored preview content. */
export async function normalizeDiscussionAttachments(
  env: SecurityEnv,
  raw: unknown,
  threadId: string,
  userId: string,
) {
  if (raw === undefined) return [];
  if (!Array.isArray(raw) || raw.length > MAX_WORK_REQUEST_FILES)
    throw new HttpError(400, "Choose up to 10 attachments");
  return Promise.all(
    raw.map(async (value: unknown) => {
      if (!value || typeof value !== "object")
        throw new HttpError(400, "Invalid attachment");
      const file = value as Record<string, unknown>;
      if (file.kind !== "file" || !isWorkRequestFileId(file.fileId))
        throw new HttpError(400, "Invalid attachment");
      const stored = await verifyWorkRequestFile(
        env,
        file.fileId,
        threadId,
        userId,
        file.sizeBytes,
      );
      const object = await env.CONCLAVE_ARTIFACTS!.head(
        workRequestFileKey(file.fileId),
      );
      return {
        kind: "file",
        fileId: file.fileId,
        name: object!.customMetadata?.name ?? "Attachment",
        sizeBytes: object!.size,
        mediaType:
          object!.httpMetadata?.contentType ?? "application/octet-stream",
        ...stored,
      };
    }),
  );
}

/** Downloads remain authenticated and restricted to accepted Thread references. */
export async function handleDownloadThreadFile(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  fileId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeThreadAccess(request, env, threadId, "view", accessContext);
  if (!isWorkRequestFileId(fileId)) throw new HttpError(404, "File not found");
  const reference = await env.CONCLAVE_DB.prepare(
    `SELECT 1 AS present FROM discussion_messages dm, json_each(dm.attachments_json) f
    WHERE dm.thread_id = ?1 AND json_extract(f.value, '$.fileId') = ?2
    UNION ALL SELECT 1 AS present FROM work_requests wr, json_each(wr.input_json, '$.attachments') f
    WHERE wr.thread_id = ?1 AND json_extract(f.value, '$.fileId') = ?2 LIMIT 1`,
  )
    .bind(threadId, fileId)
    .first();
  if (!reference) throw new HttpError(404, "File not found");
  const object = await env.CONCLAVE_ARTIFACTS?.get(workRequestFileKey(fileId));
  if (!object || object.customMetadata?.threadId !== threadId)
    throw new HttpError(404, "File not found");
  return new Response(object.body, {
    headers: {
      "Content-Type": "application/octet-stream",
      "Content-Disposition": "attachment",
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
