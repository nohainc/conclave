import {
  authorizeProfileAdmin as authorizeSecurityProfileAdmin,
  type SecurityContext,
} from "@conclave/security";

import type { SecurityEnv } from "./http-security.js";
import { securityContext } from "./http-security.js";

import { HttpError } from "./http-security.js";

export function assertSafeProviderMetadata(
  value: unknown,
): Record<string, unknown> {
  if (value === undefined) return {};
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpError(400, "providerMetadata must be an object");
  }
  const forbidden = /secret|token|password|api[_-]?key|private/i;
  const metadata = value as Record<string, unknown>;
  if (Object.keys(metadata).some((key) => forbidden.test(key))) {
    throw new HttpError(400, "providerMetadata cannot contain credentials");
  }
  return metadata;
}

export async function authorizeToolProfileAdmin(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
  permission: "profiles:admin" | "profiles:release:manage" = "profiles:admin",
): Promise<SecurityContext> {
  const actor = await securityContext(request, env, ctx);
  const adminUserIds = (env.CONCLAVE_PROFILE_ADMIN_USER_IDS ?? "")
    .split(",")
    .map((userId) => userId.trim())
    .filter(Boolean);
  try {
    authorizeSecurityProfileAdmin(actor, adminUserIds, permission);
  } catch {
    throw new HttpError(403, "Profile administrator authorization is required");
  }
  return actor;
}

export async function readToolProfileAdminBody(
  request: Request,
  allowed: readonly string[],
): Promise<Record<string, unknown>> {
  const maxBytes = 384 * 1024;
  const contentLength = Number(request.headers.get("content-length") ?? 0);
  if (contentLength > maxBytes)
    throw new HttpError(413, "request body is too large");
  const reader = request.body?.getReader();
  if (!reader) throw new HttpError(400, "request body is required");
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxBytes) {
        await reader.cancel();
        throw new HttpError(413, "request body is too large");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new HttpError(400, "request body must be valid JSON");
  }
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    Object.keys(value).some((key) => !allowed.includes(key))
  ) {
    throw new HttpError(400, "request body contains unsupported fields");
  }
  return value as Record<string, unknown>;
}

export function toolProfileReleaseVersion(value: string): number {
  if (!/^\d{1,10}$/.test(value))
    throw new HttpError(400, "releaseVersion is invalid");
  const version = Number(value);
  if (
    !Number.isSafeInteger(version) ||
    version < 1 ||
    version > 2_147_483_647
  ) {
    throw new HttpError(400, "releaseVersion is invalid");
  }
  return version;
}
