import { computePackageDigest } from "@conclave/security";
import {
  HttpError,
  artifactName,
  authorizeThreadAccess,
  json,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";

/** Per-file limit for Work Request file inputs; there is no total limit. */
export const MAX_WORK_REQUEST_FILE_BYTES = 2 * 1024 * 1024;
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
    "execute",
    accessContext,
  );
  const bucket = env.CONCLAVE_ARTIFACTS;
  if (!bucket) throw new HttpError(503, "File storage is not configured");
  const declared = request.headers.get("content-length");
  if (declared !== null) {
    const length = Number(declared);
    if (!Number.isSafeInteger(length) || length > MAX_WORK_REQUEST_FILE_BYTES)
      throw new HttpError(413, "File exceeds the 2 MB limit");
  }
  const body = await request.arrayBuffer();
  if (body.byteLength > MAX_WORK_REQUEST_FILE_BYTES)
    throw new HttpError(413, "File exceeds the 2 MB limit");
  const url = new URL(request.url);
  const name = artifactName(
    url.searchParams.get("name") ?? request.headers.get("x-file-name"),
  );
  const mediaType =
    request.headers
      .get("content-type")
      ?.split(";", 1)[0]
      ?.trim()
      .slice(0, 128) || "application/octet-stream";
  const digest = await computePackageDigest(body);
  const fileId = `wrf-${crypto.randomUUID()}`;
  await bucket.put(workRequestFileKey(fileId), body, {
    httpMetadata: { contentType: mediaType },
    customMetadata: {
      threadId,
      userId: context.userId,
      name,
      digest,
    },
  });
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
): Promise<{ digest: string }> {
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
  return { digest: meta.digest ?? "" };
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
