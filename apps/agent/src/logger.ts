import fs from "node:fs";
import path from "node:path";

/**
 * Conclave Agent Logger.
 *
 * Security rule: NEVER log tokens, authorization headers, API keys, or private credential strings.
 */

export type LogLevel = "debug" | "info" | "warn" | "error";

export interface LogEntry {
  readonly timestamp: string;
  readonly level: LogLevel;
  readonly message: string;
  readonly context?: Record<string, unknown>;
}

const REDACTION_PATTERNS = [
  /Bearer\s+[A-Za-z0-9\-_.~]+/gi,
  /sk-[A-Za-z0-9_-]{20,}/gi,
  /tok_[A-Za-z0-9_-]+/gi,
  /token=[A-Za-z0-9\-_.~]+/gi,
  /"(agentToken|token|apiKey|password|secret|authorization)":\s*"[^"]+"/gi,
];

export function redactSensitiveText(text: string): string {
  let result = text;
  for (const pattern of REDACTION_PATTERNS) {
    result = result.replace(pattern, (match) => {
      if (match.startsWith("Bearer ")) return "Bearer [REDACTED]";
      if (match.startsWith("sk-")) return "sk-[REDACTED]";
      if (match.startsWith("tok_")) return "tok_[REDACTED]";
      if (match.startsWith("token=")) return "token=[REDACTED]";
      return '"[REDACTED]": "[REDACTED]"';
    });
  }
  return result;
}

export function redactObject<T>(obj: T): T {
  if (obj === null || typeof obj !== "object") {
    if (typeof obj === "string") {
      return redactSensitiveText(obj) as unknown as T;
    }
    return obj;
  }
  if (Array.isArray(obj)) {
    return obj.map((item) => redactObject(item)) as unknown as T;
  }
  const result: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(obj as Record<string, unknown>)) {
    const lower = key.toLowerCase();
    if (
      lower.includes("token") ||
      lower.includes("secret") ||
      lower.includes("password") ||
      lower.includes("key") ||
      lower.includes("auth")
    ) {
      result[key] = "[REDACTED]";
    } else {
      result[key] = redactObject(value);
    }
  }
  return result as T;
}

export class AgentLogger {
  private readonly minLevel: LogLevel;
  private readonly logFile?: string;
  private readonly sink?: (entry: LogEntry) => void;

  constructor(
    logDirOrMinLevel?: string | LogLevel,
    sink?: (entry: LogEntry) => void,
  ) {
    if (
      logDirOrMinLevel === "debug" ||
      logDirOrMinLevel === "info" ||
      logDirOrMinLevel === "warn" ||
      logDirOrMinLevel === "error"
    ) {
      this.minLevel = logDirOrMinLevel;
    } else if (typeof logDirOrMinLevel === "string") {
      this.minLevel = "info";
      try {
        fs.mkdirSync(logDirOrMinLevel, { recursive: true });
        this.logFile = path.join(logDirOrMinLevel, "conclave-agent.log");
      } catch {
        // ignore dir creation failure
      }
    } else {
      this.minLevel = "info";
    }
    this.sink = sink;
  }

  static redact(text: string): string {
    return redactSensitiveText(text);
  }

  private shouldLog(level: LogLevel): boolean {
    const levels: Record<LogLevel, number> = {
      debug: 10,
      info: 20,
      warn: 30,
      error: 40,
    };
    return levels[level] >= levels[this.minLevel];
  }

  private write(
    level: LogLevel,
    message: string,
    context?: Record<string, unknown>,
  ): void {
    if (!this.shouldLog(level)) return;
    const cleanMessage = redactSensitiveText(message);
    const cleanContext = context ? redactObject(context) : undefined;
    const entry: LogEntry = {
      timestamp: new Date().toISOString(),
      level,
      message: cleanMessage,
      ...(cleanContext ? { context: cleanContext } : {}),
    };

    if (this.sink) {
      this.sink(entry);
    } else {
      const line = `[${entry.timestamp}] [${entry.level.toUpperCase()}] ${entry.message}${entry.context ? ` ${JSON.stringify(entry.context)}` : ""}`;
      if (level === "error") {
        console.error(line);
      } else if (level === "warn") {
        console.warn(line);
      } else {
        console.log(line);
      }
    }

    if (this.logFile) {
      try {
        const line = `[${entry.timestamp}] [${entry.level.toUpperCase()}] ${entry.message}${entry.context ? ` ${JSON.stringify(entry.context)}` : ""}\n`;
        fs.appendFileSync(this.logFile, line, "utf8");
      } catch {
        // ignore disk write errors
      }
    }
  }

  debug(message: string, context?: Record<string, unknown>): void {
    this.write("debug", message, context);
  }

  info(message: string, context?: Record<string, unknown>): void {
    this.write("info", message, context);
  }

  warn(message: string, context?: Record<string, unknown>): void {
    this.write("warn", message, context);
  }

  error(message: string, context?: Record<string, unknown>): void {
    this.write("error", message, context);
  }
}
