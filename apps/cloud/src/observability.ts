export interface CorrelationContext {
  requestId?: string;
  eventId?: string;
  workspaceId?: string;
  runId?: string;
  taskId?: string;
  attemptId?: string;
  assignmentId?: string;
  hostId?: string;
  workerId?: string;
  credentialProfileId?: string;
}

const SECRET_KEY =
  /(secret|token|password|api[_-]?key|authorization|cookie|raw[_-]?credential|private[_-]?key)/i;
const MAX_STRING_LENGTH = 512;
const MAX_ARRAY_LENGTH = 50;
const MAX_OBJECT_KEYS = 80;

export function requestIdFor(request: Request): string {
  const supplied = request.headers.get("x-request-id")?.trim();
  return supplied && supplied.length <= 128 ? supplied : crypto.randomUUID();
}

export function isTrustedRealtimeOrigin(
  request: Request,
  configuredOrigins: readonly string[] = [],
): boolean {
  const origin = request.headers.get("origin")?.replace(/\/$/, "");
  if (!origin) return false;
  const requestOrigin = new URL(request.url).origin;
  return new Set([requestOrigin, ...configuredOrigins]).has(origin);
}

export function sanitizeDiagnostics(value: unknown, depth = 0): unknown {
  if (depth > 5) return "[depth limited]";
  if (typeof value === "string") {
    return value.length > MAX_STRING_LENGTH
      ? `${value.slice(0, MAX_STRING_LENGTH)}…`
      : value;
  }
  if (
    value === null ||
    typeof value === "number" ||
    typeof value === "boolean"
  ) {
    return value;
  }
  if (Array.isArray(value)) {
    return value
      .slice(0, MAX_ARRAY_LENGTH)
      .map((item) => sanitizeDiagnostics(item, depth + 1));
  }
  if (typeof value === "object") {
    const result: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(value).slice(0, MAX_OBJECT_KEYS)) {
      result[key] = SECRET_KEY.test(key)
        ? "[redacted]"
        : sanitizeDiagnostics(item, depth + 1);
    }
    return result;
  }
  return `[${typeof value}]`;
}

export function structuredLogRecord(
  level: "debug" | "info" | "warn" | "error",
  message: string,
  correlation: CorrelationContext = {},
  details: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    timestamp: new Date().toISOString(),
    level,
    message,
    correlation: sanitizeDiagnostics(correlation),
    ...(Object.keys(details).length > 0
      ? { details: sanitizeDiagnostics(details) }
      : {}),
  };
}

export function logStructured(
  level: "debug" | "info" | "warn" | "error",
  message: string,
  correlation: CorrelationContext = {},
  details: Record<string, unknown> = {},
): void {
  const record = JSON.stringify(
    structuredLogRecord(level, message, correlation, details),
  );
  if (level === "error") console.error(record);
  else if (level === "warn") console.warn(record);
  else console.log(record);
}

export function withRequestId(response: Response, requestId: string): Response {
  if (response.status === 101) return response;
  const headers = new Headers(response.headers);
  headers.set("x-request-id", requestId);
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}
