import { createHash } from "node:crypto";
import { readFile, readdir, stat, writeFile } from "node:fs/promises";
import { isAbsolute, relative, resolve, sep } from "node:path";
import { spawn } from "node:child_process";

import type { GoalSummary } from "@conclave/core";

export interface RuntimeConfig {
  readonly environment: string;
  readonly apiBaseUrl: URL;
}

export function loadRuntimeConfig(
  env: Record<string, string | undefined>,
): RuntimeConfig {
  const environment = env.CONCLAVE_ENVIRONMENT ?? "development";
  const apiBaseUrl = new URL(
    env.CONCLAVE_API_BASE_URL ?? "http://localhost:8787",
  );
  return { environment, apiBaseUrl };
}

export function describeRuntimeGoal(goal: GoalSummary): string {
  return `${goal.id}: ${goal.objective} [${goal.status}]`;
}

export type RuntimeOperationKind =
  "read_file" | "search" | "write_file" | "git" | "shell" | "check" | "build";

export type RuntimeGitAction = "status" | "diff" | "branch";

export interface RuntimeApproval {
  readonly approvalId: string;
  readonly operationKinds: readonly RuntimeOperationKind[];
  readonly expiresAt: string;
}

export interface RuntimeRequestBase {
  readonly requestId: string;
  readonly repositoryId: string;
  readonly approval: RuntimeApproval;
}

export type RuntimeOperation =
  | (RuntimeRequestBase & {
      readonly kind: "read_file";
      readonly path: string;
      readonly maxBytes?: number;
    })
  | (RuntimeRequestBase & {
      readonly kind: "search";
      readonly query: string;
      readonly path?: string;
      readonly maxResults?: number;
    })
  | (RuntimeRequestBase & {
      readonly kind: "write_file";
      readonly path: string;
      readonly content: string;
      readonly expectedDigest?: string;
    })
  | (RuntimeRequestBase & {
      readonly kind: "git";
      readonly action: RuntimeGitAction;
      readonly path?: string;
    })
  | (RuntimeRequestBase & {
      readonly kind: "shell" | "check" | "build";
      readonly command: readonly string[];
      readonly cwd?: string;
      readonly timeoutMs?: number;
    });

export interface RuntimeEvidence {
  readonly evidenceId: string;
  readonly requestId: string;
  readonly repositoryId: string;
  readonly operation: RuntimeOperationKind;
  readonly status: "succeeded" | "failed" | "rejected" | "timed_out";
  readonly summary: string;
  readonly mediaType: "application/json" | "text/plain";
  readonly content: string;
  readonly contentDigest: string;
  readonly exitCode: number | null;
  readonly command: readonly string[] | null;
  readonly startedAt: string;
  readonly finishedAt: string;
  readonly durationMs: number;
  readonly audit: {
    readonly approvalId: string;
    readonly root: string;
    readonly actor: "local-runtime";
  };
}

export interface RuntimeRepository {
  readonly id: string;
  readonly root: string;
  readonly revision?: string;
}

export interface RuntimePolicy {
  readonly repositories: readonly RuntimeRepository[];
  readonly allowedCommands?: Readonly<
    Record<"shell" | "check" | "build", readonly string[]>
  >;
  readonly maxReadBytes?: number;
  readonly maxWriteBytes?: number;
  readonly maxSearchResults?: number;
  readonly defaultTimeoutMs?: number;
}

export interface RuntimeTransport {
  connect(): Promise<void>;
  receive(): AsyncIterable<RuntimeOperation>;
  send(evidence: RuntimeEvidence): Promise<void>;
  disconnect?(): Promise<void>;
}

export class RuntimeSecurityError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RuntimeSecurityError";
  }
}

function digest(content: string): string {
  return createHash("sha256").update(content).digest("hex");
}

function idFor(requestId: string, contentDigest: string): string {
  return `evidence-${digest(`${requestId}:${contentDigest}`).slice(0, 20)}`;
}

function asString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new RuntimeSecurityError(`Runtime request field ${field} is invalid`);
  }
  return value;
}

function asRecord(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new RuntimeSecurityError("Runtime request must be an object");
  }
  return value as Record<string, unknown>;
}

function parseApproval(value: unknown): RuntimeApproval {
  const record = asRecord(value);
  const kinds = record.operationKinds;
  if (!Array.isArray(kinds) || kinds.some((kind) => typeof kind !== "string")) {
    throw new RuntimeSecurityError(
      "Runtime approval operationKinds is invalid",
    );
  }
  return {
    approvalId: asString(record.approvalId, "approval.approvalId"),
    operationKinds: kinds as RuntimeOperationKind[],
    expiresAt: asString(record.expiresAt, "approval.expiresAt"),
  };
}

export function parseRuntimeOperation(value: unknown): RuntimeOperation {
  const record = asRecord(value);
  const kind = asString(record.kind, "kind") as RuntimeOperationKind;
  const base = {
    requestId: asString(record.requestId, "requestId"),
    repositoryId: asString(record.repositoryId, "repositoryId"),
    approval: parseApproval(record.approval),
  };

  if (kind === "read_file") {
    return { ...base, kind, path: asString(record.path, "path") };
  }
  if (kind === "search") {
    return {
      ...base,
      kind,
      query: asString(record.query, "query"),
      ...(typeof record.path === "string" ? { path: record.path } : {}),
    };
  }
  if (kind === "write_file") {
    return {
      ...base,
      kind,
      path: asString(record.path, "path"),
      content:
        typeof record.content === "string"
          ? record.content
          : (() => {
              throw new RuntimeSecurityError(
                "Runtime request field content is invalid",
              );
            })(),
    };
  }
  if (kind === "git") {
    const action = asString(record.action, "action") as RuntimeGitAction;
    if (!["status", "diff", "branch"].includes(action)) {
      throw new RuntimeSecurityError("Git action is not supported");
    }
    return {
      ...base,
      kind,
      action,
      ...(typeof record.path === "string" ? { path: record.path } : {}),
    };
  }
  if (kind === "shell" || kind === "check" || kind === "build") {
    if (
      !Array.isArray(record.command) ||
      record.command.length === 0 ||
      record.command.some(
        (part) => typeof part !== "string" || part.length === 0,
      )
    ) {
      throw new RuntimeSecurityError(
        "Runtime command must be a non-empty string array",
      );
    }
    return {
      ...base,
      kind,
      command: record.command as string[],
      ...(typeof record.cwd === "string" ? { cwd: record.cwd } : {}),
    };
  }
  throw new RuntimeSecurityError(`Runtime operation ${kind} is not supported`);
}

function isWithin(root: string, candidate: string): boolean {
  const path = resolve(candidate);
  const prefix = root.endsWith(sep) ? root : `${root}${sep}`;
  return path === root || path.startsWith(prefix);
}

async function collectFiles(
  root: string,
  current: string,
  output: string[],
  limit: number,
): Promise<void> {
  if (output.length >= limit) return;
  const entries = await readdir(current, { withFileTypes: true });
  for (const entry of entries) {
    if (
      output.length >= limit ||
      entry.name === ".git" ||
      entry.name === "node_modules" ||
      entry.name === ".dart_tool"
    ) {
      continue;
    }
    const fullPath = resolve(current, entry.name);
    if (entry.isDirectory()) {
      await collectFiles(root, fullPath, output, limit);
    } else {
      output.push(relative(root, fullPath));
    }
  }
}

function runCommand(
  command: readonly string[],
  cwd: string,
  timeoutMs: number,
): Promise<{
  stdout: string;
  stderr: string;
  exitCode: number | null;
  status: RuntimeEvidence["status"];
}> {
  return new Promise((resolvePromise) => {
    const executable = command[0];
    if (!executable) {
      resolvePromise({
        stdout: "",
        stderr: "No command supplied",
        exitCode: null,
        status: "failed",
      });
      return;
    }
    const child = spawn(executable, command.slice(1), {
      cwd,
      shell: false,
      windowsHide: true,
    });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
    }, timeoutMs);
    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
    });
    child.on("error", (error: Error) => {
      clearTimeout(timer);
      resolvePromise({
        stdout,
        stderr: `${stderr}${error.message}`,
        exitCode: null,
        status: "failed",
      });
    });
    child.on("close", (exitCode) => {
      clearTimeout(timer);
      resolvePromise({
        stdout,
        stderr,
        exitCode,
        status: timedOut
          ? "timed_out"
          : exitCode === 0
            ? "succeeded"
            : "failed",
      });
    });
  });
}

export class LocalRuntime {
  private readonly repositories = new Map<string, RuntimeRepository>();
  private readonly policy: Required<
    Pick<
      RuntimePolicy,
      "maxReadBytes" | "maxWriteBytes" | "maxSearchResults" | "defaultTimeoutMs"
    >
  > &
    RuntimePolicy;

  constructor(policy: RuntimePolicy) {
    this.policy = {
      ...policy,
      maxReadBytes: policy.maxReadBytes ?? 512_000,
      maxWriteBytes: policy.maxWriteBytes ?? 512_000,
      maxSearchResults: policy.maxSearchResults ?? 200,
      defaultTimeoutMs: policy.defaultTimeoutMs ?? 120_000,
    };
    for (const repository of policy.repositories) {
      const root = resolve(repository.root);
      if (this.repositories.has(repository.id)) {
        throw new RuntimeSecurityError(`Duplicate repository ${repository.id}`);
      }
      this.repositories.set(repository.id, { ...repository, root });
    }
  }

  async execute(request: RuntimeOperation): Promise<RuntimeEvidence> {
    const startedAt = new Date();
    const repository = this.repositories.get(request.repositoryId);
    try {
      if (!repository) {
        throw new RuntimeSecurityError("Repository is not registered");
      }
      this.authorize(request, startedAt);
      const result = await this.perform(request, repository);
      return this.evidence(
        request,
        repository,
        startedAt,
        result.status,
        result.summary,
        result.content,
        result.exitCode,
        result.command,
      );
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "Runtime operation failed";
      const status =
        error instanceof RuntimeSecurityError ? "rejected" : "failed";
      return this.evidence(
        request,
        repository,
        startedAt,
        status,
        message,
        "",
        null,
        null,
      );
    }
  }

  private authorize(request: RuntimeOperation, now: Date): void {
    if (!request.approval.operationKinds.includes(request.kind)) {
      throw new RuntimeSecurityError(
        "Operation is not covered by the approval",
      );
    }
    if (Date.parse(request.approval.expiresAt) <= now.getTime()) {
      throw new RuntimeSecurityError("Runtime approval has expired");
    }
  }

  private resolvePath(repository: RuntimeRepository, path = "."): string {
    if (isAbsolute(path)) {
      throw new RuntimeSecurityError("Absolute paths are not allowed");
    }
    const candidate = resolve(repository.root, path);
    if (!isWithin(repository.root, candidate)) {
      throw new RuntimeSecurityError("Path escapes the registered repository");
    }
    return candidate;
  }

  private async perform(
    request: RuntimeOperation,
    repository: RuntimeRepository,
  ): Promise<{
    status: RuntimeEvidence["status"];
    summary: string;
    content: string;
    exitCode: number | null;
    command: readonly string[] | null;
  }> {
    switch (request.kind) {
      case "read_file": {
        const path = this.resolvePath(repository, request.path);
        const content = await readFile(path, "utf8");
        if (
          Buffer.byteLength(content) >
          Math.min(
            request.maxBytes ?? this.policy.maxReadBytes,
            this.policy.maxReadBytes,
          )
        ) {
          throw new RuntimeSecurityError("File exceeds the read limit");
        }
        return {
          status: "succeeded",
          summary: `Read ${relative(repository.root, path)}`,
          content,
          exitCode: 0,
          command: null,
        };
      }
      case "search": {
        const start = this.resolvePath(repository, request.path);
        const info = await stat(start);
        const files: string[] = [];
        if (info.isDirectory()) {
          await collectFiles(
            repository.root,
            start,
            files,
            this.policy.maxSearchResults,
          );
        } else {
          files.push(relative(repository.root, start));
        }
        const matches: string[] = [];
        const limit = Math.min(
          request.maxResults ?? this.policy.maxSearchResults,
          this.policy.maxSearchResults,
        );
        for (const file of files) {
          if (matches.length >= limit) break;
          const content = await readFile(
            resolve(repository.root, file),
            "utf8",
          ).catch(() => null);
          if (content === null) continue;
          content.split(/\r?\n/).forEach((line, index) => {
            if (line.includes(request.query) && matches.length < limit) {
              matches.push(`${file}:${index + 1}:${line}`);
            }
          });
        }
        return {
          status: "succeeded",
          summary: `Found ${matches.length} matches for ${request.query}`,
          content: matches.join("\n"),
          exitCode: 0,
          command: null,
        };
      }
      case "write_file": {
        const path = this.resolvePath(repository, request.path);
        if (Buffer.byteLength(request.content) > this.policy.maxWriteBytes) {
          throw new RuntimeSecurityError("File exceeds the write limit");
        }
        const current = await readFile(path, "utf8").catch(() => null);
        if (
          request.expectedDigest &&
          digest(current ?? "") !== request.expectedDigest
        ) {
          throw new RuntimeSecurityError("Expected file digest does not match");
        }
        await writeFile(path, request.content, "utf8");
        return {
          status: "succeeded",
          summary: `Wrote ${relative(repository.root, path)}`,
          content: JSON.stringify({
            path: relative(repository.root, path),
            digest: digest(request.content),
            bytes: Buffer.byteLength(request.content),
          }),
          exitCode: 0,
          command: null,
        };
      }
      case "git": {
        const args =
          request.action === "status"
            ? ["git", "status", "--short", "--branch"]
            : request.action === "diff"
              ? ["git", "diff", "--no-ext-diff"]
              : ["git", "branch", "--show-current"];
        const cwd = this.resolvePath(repository, request.path);
        const result = await runCommand(
          args,
          cwd,
          this.policy.defaultTimeoutMs,
        );
        return {
          ...result,
          summary: `Git ${request.action} completed`,
          content: `${result.stdout}${result.stderr}`.trim(),
          command: args,
        };
      }
      case "shell":
      case "check":
      case "build": {
        const allowed = this.policy.allowedCommands?.[request.kind];
        if (!allowed?.includes(request.command[0] ?? "")) {
          throw new RuntimeSecurityError(
            `Command ${request.command[0] ?? ""} is not allowed for ${request.kind}`,
          );
        }
        const cwd = this.resolvePath(repository, request.cwd);
        const result = await runCommand(
          request.command,
          cwd,
          request.timeoutMs ?? this.policy.defaultTimeoutMs,
        );
        return {
          ...result,
          summary: `${request.kind} command ${request.command[0]} completed`,
          content: `${result.stdout}${result.stderr}`.trim(),
          command: request.command,
        };
      }
    }
  }

  private evidence(
    request: RuntimeOperation,
    repository: RuntimeRepository | undefined,
    startedAt: Date,
    status: RuntimeEvidence["status"],
    summary: string,
    content: string,
    exitCode: number | null,
    command: readonly string[] | null,
  ): RuntimeEvidence {
    const finishedAt = new Date();
    const contentDigest = digest(content);
    return {
      evidenceId: idFor(request.requestId, contentDigest),
      requestId: request.requestId,
      repositoryId: request.repositoryId,
      operation: request.kind,
      status,
      summary,
      mediaType: command ? "text/plain" : "application/json",
      content,
      contentDigest,
      exitCode,
      command,
      startedAt: startedAt.toISOString(),
      finishedAt: finishedAt.toISOString(),
      durationMs: finishedAt.getTime() - startedAt.getTime(),
      audit: {
        approvalId: request.approval.approvalId,
        root: repository?.root ?? "unresolved",
        actor: "local-runtime",
      },
    };
  }
}

export class OutboundRuntimeSession {
  constructor(
    private readonly runtime: LocalRuntime,
    private readonly transport: RuntimeTransport,
  ) {}

  async run(): Promise<void> {
    await this.transport.connect();
    try {
      for await (const rawRequest of this.transport.receive()) {
        const request = parseRuntimeOperation(rawRequest);
        await this.transport.send(await this.runtime.execute(request));
      }
    } finally {
      await this.transport.disconnect?.();
    }
  }
}
