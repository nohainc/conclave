import { securityContext, HttpError, json } from "./http-security.js";
import type { SecurityEnv } from "./http-security.js";

const MAX_AVATAR_BYTES = 5 * 1024 * 1024;
const AVATAR_TYPES = new Set([
  "image/gif",
  "image/jpeg",
  "image/png",
  "image/webp",
]);

function avatarKey(value: string | null | undefined): string | null {
  if (!value?.startsWith("r2://")) return null;
  return value.slice("r2://".length);
}

export function avatarUrlFor(
  request: Request,
  userId: string,
  value: string | null | undefined,
): string | null {
  if (!value) return null;
  if (!value.startsWith("r2://")) return value;
  const key = value.slice("r2://".length);
  const version = key.split("/").pop() ?? key;
  const url = new URL(
    `/api/users/${encodeURIComponent(userId)}/avatar`,
    request.url,
  );
  url.searchParams.set("v", version);
  return url.toString();
}

export async function handleUploadAvatar(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (request.method !== "PUT") throw new HttpError(405, "Use PUT for avatars");

  const mediaType =
    request.headers.get("content-type")?.split(";", 1)[0]?.trim() ?? "";
  if (!AVATAR_TYPES.has(mediaType)) {
    throw new HttpError(415, "Avatar must be a JPEG, PNG, GIF, or WebP image");
  }
  const declaredLength = Number(request.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > MAX_AVATAR_BYTES) {
    throw new HttpError(413, "Avatar image must be 5 MB or smaller");
  }
  const body = await request.arrayBuffer();
  if (body.byteLength === 0 || body.byteLength > MAX_AVATAR_BYTES) {
    throw new HttpError(413, "Avatar image must be between 1 byte and 5 MB");
  }
  const bucket = env.CONCLAVE_ARTIFACTS;
  if (!bucket) throw new HttpError(503, "Avatar storage is not configured");

  const old = await env.CONCLAVE_DB.prepare(
    "SELECT avatar_url AS avatarUrl FROM users WHERE id = ?1",
  )
    .bind(context.userId)
    .first<{ avatarUrl: string | null }>();
  if (!old) throw new HttpError(404, "User not found");

  const key = `user-avatars/${context.userId}/${crypto.randomUUID()}`;
  await bucket.put(key, body, {
    httpMetadata: { contentType: mediaType },
    customMetadata: { userId: context.userId },
  });
  const storedValue = `r2://${key}`;
  try {
    await env.CONCLAVE_DB.prepare(
      "UPDATE users SET avatar_url = ?1, updated_at = ?2 WHERE id = ?3",
    )
      .bind(storedValue, new Date().toISOString(), context.userId)
      .run();
  } catch (error) {
    await bucket.delete(key).catch(() => undefined);
    throw error;
  }

  const oldKey = avatarKey(old.avatarUrl);
  if (oldKey) await bucket.delete(oldKey).catch(() => undefined);
  return json({
    avatarUrl: avatarUrlFor(request, context.userId, storedValue),
  });
}

export async function handleGetAvatar(
  request: Request,
  env: SecurityEnv,
  userId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const canView =
    context.userId === userId ||
    Boolean(
      await env.CONCLAVE_DB.prepare(
        `SELECT 1 FROM people_relationships
         WHERE (user_low_id = ?1 AND user_high_id = ?2)
            OR (user_low_id = ?2 AND user_high_id = ?1)
         LIMIT 1`,
      )
        .bind(context.userId, userId)
        .first(),
    );
  if (!canView) throw new HttpError(404, "Avatar not found");

  const row = await env.CONCLAVE_DB.prepare(
    "SELECT avatar_url AS avatarUrl FROM users WHERE id = ?1 AND status = 'active'",
  )
    .bind(userId)
    .first<{ avatarUrl: string | null }>();
  const key = avatarKey(row?.avatarUrl);
  if (!key) throw new HttpError(404, "Avatar not found");
  const bucket = env.CONCLAVE_ARTIFACTS;
  if (!bucket) throw new HttpError(503, "Avatar storage is not configured");
  const object = await bucket.get(key);
  if (!object) throw new HttpError(404, "Avatar not found");

  const headers = new Headers({
    "cache-control": "private, max-age=300",
    "content-type":
      object.httpMetadata?.contentType ?? "application/octet-stream",
  });
  if (object.httpEtag) headers.set("etag", object.httpEtag);
  return new Response(object.body, { headers });
}
