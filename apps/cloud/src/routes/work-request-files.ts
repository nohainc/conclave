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

/** Per-file limit for Work Request file inputs; there is no total limit. */
export const MAX_WORK_REQUEST_FILE_BYTES = 10 * 1024 * 1024;
export const MAX_WORK_REQUEST_FILES = 10;

const FILE_ID_PATTERN =
  /^wrf-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

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
  const { context } = await authorizeThreadAccess(
    request,
    env,
    threadId,
    new URL(request.url).searchParams.get("purpose") === "discussion"
      ? "discuss"
      : "execute",
    accessContext,
  );
  const bucket = env.CONCLAVE_ARTIFACTS;
  if (!bucket) throw new HttpError(503, "File storage is not configured");
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
  const url = new URL(request.url);
  const name = artifactName(
    url.searchParams.get("name") ?? request.headers.get("x-file-name"),
  );
  const mediaType =
    (submittedType ?? request.headers.get("content-type"))
      ?.split(";", 1)[0]
      ?.trim()
      .slice(0, 128) || "application/octet-stream";
  const previewText = fileTextPreview(name, mediaType, body);
  const digest = await computePackageDigest(body);
  const fileId = `wrf-${crypto.randomUUID()}`;
  await bucket.put(workRequestFileKey(fileId), body, {
    httpMetadata: { contentType: mediaType },
    customMetadata: {
      threadId,
      userId: context.userId,
      name,
      digest,
      ...(previewText || previewImage ? { hasPreview: "1" } : {}),
    },
  });
  if (previewText || previewImage)
    await bucket.put(
      `${workRequestFileKey(fileId)}/preview`,
      JSON.stringify({ previewText, previewImage }),
      {
        httpMetadata: { contentType: "application/json" },
      },
    );
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

type AttachmentRecord = Record<string, unknown>;

/**
 * Adds file bytes from R2 to an outgoing `assignment.start` payload. The
 * bytes are never written back to D1; the Workspace materializes them at
 * `.conclave/inputs/<work-request-id>/file-NNN` for the AI CLI.
 */
export async function hydrateWorkRequestFiles(
  env: { readonly CONCLAVE_ARTIFACTS?: R2Bucket },
  payload: unknown,
): Promise<unknown> {
  const input = (payload as { input?: { attachments?: unknown } } | null)
    ?.input;
  if (!input || !Array.isArray(input.attachments)) return payload;
  const threadId = (payload as { threadId?: unknown }).threadId;
  const attachments: AttachmentRecord[] = [];
  for (const attachment of input.attachments as AttachmentRecord[]) {
    if (
      !attachment ||
      attachment.kind !== "file" ||
      !isWorkRequestFileId(attachment.fileId)
    ) {
      attachments.push(attachment);
      continue;
    }
    const object = await env.CONCLAVE_ARTIFACTS?.get(
      workRequestFileKey(attachment.fileId),
    );
    if (
      !object ||
      object.size !== attachment.sizeBytes ||
      (typeof threadId === "string" &&
        object.customMetadata?.threadId !== threadId)
    )
      throw new HttpError(409, "Attached file content is unavailable");
    const bytes = new Uint8Array(await object.arrayBuffer());
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000)
      binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    attachments.push({ ...attachment, contentBase64: btoa(binary) });
  }
  return { ...(payload as object), input: { ...input, attachments } };
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
