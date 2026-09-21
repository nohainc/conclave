import { createHash } from "node:crypto";
import {
  realpath,
  readFile,
  readdir,
  stat,
  unlink,
  writeFile,
} from "node:fs/promises";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import { realpathSync } from "node:fs";
import { spawn } from "node:child_process";

import type {
  GoalSummary,
  WorkerExecutionRequest,
  WorkerExecutionResult,
  WorkerType,
  WorkerAvailability,
} from "@conclave/core";
import type { ImplementationOperation } from "@conclave/protocol";

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
  | "read_file"
  | "search"
  | "write_file"
  | "patch_file"
  | "delete_file"
  | "git"
  | "shell"
  | "check"
  | "build";

export type RuntimeGitAction = "status" | "diff" | "branch";

export interface RuntimeApproval {
  readonly approvalId: string;
  readonly organizationId: string;
  readonly projectId: string;
  readonly runId: string;
  readonly taskId: string;
  readonly operationKinds: readonly RuntimeOperationKind[];
  readonly expiresAt: string;
}

export interface RuntimeRequestBase {
  readonly requestId: string;
  readonly organizationId: string;
  readonly projectId: string;
  readonly runId: string;
  readonly taskId: string;
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
      readonly kind: "patch_file";
      readonly path: string;
      readonly patches: readonly {
        readonly oldText: string;
        readonly newText: string;
        readonly maxReplacements?: number;
      }[];
      readonly expectedDigest?: string;
    })
  | (RuntimeRequestBase & {
      readonly kind: "delete_file";
      readonly path: string;
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
  readonly organizationId: string;
  readonly projectId: string;
  readonly runId: string;
  readonly taskId: string;
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
  readonly stdoutTruncated?: boolean;
  readonly stderrTruncated?: boolean;
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
  readonly maxStdoutBytes?: number;
  readonly maxStderrBytes?: number;
}

export interface RuntimeTransport {
  connect(): Promise<void>;
  receive(): AsyncIterable<
    RuntimeOperation | RuntimeControl | RuntimeWorkerExecutionRequest
  >;
  send(evidence: RuntimeEvidence): Promise<void>;
  announceWorkers?(workers: readonly RuntimeWorkerDescriptor[]): Promise<void>;
  sendWorkerResult?(result: RuntimeWorkerExecutionResult): Promise<void>;
  acknowledge?(requestId: string): Promise<void>;
  reconnect?(): Promise<void>;
  disconnect?(): Promise<void>;
}

export interface RuntimeWorkerDescriptor {
  readonly workerId: string;
  readonly connectionId: string;
  readonly name: string;
  readonly type: Exclude<WorkerType, "runtime">;
  readonly roles: readonly string[];
  readonly capabilities: readonly string[];
  readonly permissions: readonly string[];
  readonly independenceKey: string;
  readonly availability: WorkerAvailability;
}

export interface RuntimeWorkerExecutionRequest {
  readonly type: "worker_execute";
  readonly organizationId: string;
  readonly projectId: string;
  readonly request: WorkerExecutionRequest;
}

export interface RuntimeWorkerExecutionResult {
  readonly type: "worker_result";
  readonly requestId: string;
  readonly result: WorkerExecutionResult;
}

export interface LocalWorkerExecutor {
  readonly descriptor: RuntimeWorkerDescriptor;
  execute(request: WorkerExecutionRequest): Promise<WorkerExecutionResult>;
}

export type RuntimeControl = {
  readonly type: "cancel";
  readonly requestId: string;
};

export interface WebSocketRuntimeTransportOptions {
  readonly url: string | URL;
  readonly token: string;
  readonly runtimeId: string;
  readonly organizationId: string;
  readonly projectId: string;
  readonly runId?: string;
  readonly taskId?: string;
  readonly repositoryId?: string;
}

type RuntimeTransportMessage =
  | RuntimeOperation
  | RuntimeControl
  | RuntimeWorkerExecutionRequest
  | { readonly type: "ack"; readonly requestId: string };

function isRuntimeWorkerExecutionRequest(
  value: unknown,
): value is RuntimeWorkerExecutionRequest {
  if (typeof value !== "object" || value === null) return false;
  const record = value as Record<string, unknown>;
  return (
    record.type === "worker_execute" &&
    typeof record.organizationId === "string" &&
    typeof record.projectId === "string" &&
    typeof record.request === "object" &&
    record.request !== null
  );
}

class RuntimeMessageQueue {
  private readonly messages: RuntimeTransportMessage[] = [];
  private readonly waiters: ((message: RuntimeTransportMessage) => void)[] = [];
  private closed: Error | null = null;

  push(message: RuntimeTransportMessage): void {
    const waiter = this.waiters.shift();
    if (waiter) waiter(message);
    else this.messages.push(message);
  }

  close(error: Error): void {
    this.closed = error;
    while (this.waiters.length > 0) {
      this.waiters.shift()?.({
        type: "cancel",
        requestId: "__connection_closed__",
      });
    }
  }

  async next(): Promise<RuntimeTransportMessage> {
    if (this.messages.length > 0) return this.messages.shift()!;
    if (this.closed) throw this.closed;
    return new Promise((resolve) => this.waiters.push(resolve));
  }
}

export class WebSocketRuntimeTransport implements RuntimeTransport {
  private socket: WebSocket | null = null;
  private queue = new RuntimeMessageQueue();
  private readonly acknowledgements = new Map<
    string,
    { resolve: () => void; reject: (error: Error) => void }
  >();

  constructor(private readonly options: WebSocketRuntimeTransportOptions) {}

  async connect(): Promise<void> {
    const url = new URL(this.options.url);
    url.searchParams.set("token", this.options.token);
    url.searchParams.set("runtimeId", this.options.runtimeId);
    for (const [key, value] of Object.entries({
      organizationId: this.options.organizationId,
      projectId: this.options.projectId,
      runId: this.options.runId,
      taskId: this.options.taskId,
      repositoryId: this.options.repositoryId,
    }).filter((entry): entry is [string, string] => entry[1] !== undefined)) {
      url.searchParams.set(key, value);
    }
    this.queue = new RuntimeMessageQueue();
    const socket = new WebSocket(url);
    this.socket = socket;
    await new Promise<void>((resolve, reject) => {
      socket.addEventListener("open", () => resolve(), { once: true });
      socket.addEventListener(
        "error",
        () => reject(new Error("Runtime connection failed")),
        { once: true },
      );
    });
    socket.addEventListener("message", (event) => {
      const message = JSON.parse(String(event.data)) as RuntimeTransportMessage;
      if (
        typeof message === "object" &&
        "type" in message &&
        message.type === "ack"
      ) {
        this.acknowledgements.get(message.requestId)?.resolve();
        this.acknowledgements.delete(message.requestId);
      } else {
        this.queue.push(message);
      }
    });
    socket.addEventListener("close", () => {
      const error = new Error("Runtime connection closed");
      this.queue.close(error);
      for (const acknowledgement of this.acknowledgements.values()) {
        acknowledgement.reject(error);
      }
      this.acknowledgements.clear();
      this.socket = null;
    });
  }

  async *receive(): AsyncIterable<
    RuntimeOperation | RuntimeControl | RuntimeWorkerExecutionRequest
  > {
    while (true) {
      const message = await this.queue.next();
      if (
        typeof message === "object" &&
        "type" in message &&
        message.type === "ack"
      )
        continue;
      yield message as
        RuntimeOperation | RuntimeControl | RuntimeWorkerExecutionRequest;
    }
  }

  async send(evidence: RuntimeEvidence): Promise<void> {
    if (!this.socket) throw new Error("Runtime connection is not open");
    this.socket.send(JSON.stringify({ type: "evidence", evidence }));
  }

  async announceWorkers(
    workers: readonly RuntimeWorkerDescriptor[],
  ): Promise<void> {
    if (!this.socket) throw new Error("Runtime connection is not open");
    this.socket.send(JSON.stringify({ type: "workers", workers }));
  }

  async sendWorkerResult(result: RuntimeWorkerExecutionResult): Promise<void> {
    if (!this.socket) throw new Error("Runtime connection is not open");
    this.socket.send(JSON.stringify(result));
  }

  acknowledge(requestId: string): Promise<void> {
    return new Promise((resolve, reject) => {
      this.acknowledgements.set(requestId, { resolve, reject });
    });
  }

  async reconnect(): Promise<void> {
    await this.connect();
  }

  async disconnect(): Promise<void> {
    this.socket?.close();
    this.socket = null;
  }

  cancel(requestId: string): void {
    this.socket?.send(JSON.stringify({ type: "cancel", requestId }));
  }
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
    organizationId: asString(record.organizationId, "approval.organizationId"),
    projectId: asString(record.projectId, "approval.projectId"),
    runId: asString(record.runId, "approval.runId"),
    taskId: asString(record.taskId, "approval.taskId"),
    operationKinds: kinds as RuntimeOperationKind[],
    expiresAt: asString(record.expiresAt, "approval.expiresAt"),
  };
}

export function parseRuntimeOperation(value: unknown): RuntimeOperation {
  const record = asRecord(value);
  const kind = asString(record.kind, "kind") as RuntimeOperationKind;
  const base = {
    requestId: asString(record.requestId, "requestId"),
    organizationId: asString(record.organizationId, "organizationId"),
    projectId: asString(record.projectId, "projectId"),
    runId: asString(record.runId, "runId"),
    taskId: asString(record.taskId, "taskId"),
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
      ...(typeof record.expectedDigest === "string"
        ? { expectedDigest: record.expectedDigest }
        : {}),
    };
  }
  if (kind === "patch_file") {
    const patches = record.patches;
    if (
      !Array.isArray(patches) ||
      patches.length === 0 ||
      patches.some((patch) => {
        if (typeof patch !== "object" || patch === null) return true;
        const value = patch as Record<string, unknown>;
        return (
          typeof value.oldText !== "string" || typeof value.newText !== "string"
        );
      })
    ) {
      throw new RuntimeSecurityError("Runtime patch_file patches are invalid");
    }
    const parsedPatches = patches.map((patch) => {
      const value = patch as Record<string, unknown>;
      return {
        oldText: value.oldText as string,
        newText: value.newText as string,
        ...(typeof value.maxReplacements === "number"
          ? { maxReplacements: value.maxReplacements }
          : {}),
      };
    });
    return {
      ...base,
      kind,
      path: asString(record.path, "path"),
      patches: parsedPatches,
      ...(typeof record.expectedDigest === "string"
        ? { expectedDigest: record.expectedDigest }
        : {}),
    };
  }
  if (kind === "delete_file") {
    return {
      ...base,
      kind,
      path: asString(record.path, "path"),
      ...(typeof record.expectedDigest === "string"
        ? { expectedDigest: record.expectedDigest }
        : {}),
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

export function implementationOperationsToRuntimeOperations(
  repositoryId: string,
  approval: RuntimeApproval,
  operations: readonly ImplementationOperation[],
): readonly RuntimeOperation[] {
  return operations.map((operation, index) => ({
    requestId: `implementation-${index + 1}`,
    organizationId: approval.organizationId,
    projectId: approval.projectId,
    runId: approval.runId,
    taskId: approval.taskId,
    repositoryId,
    approval,
    ...operation,
  })) as RuntimeOperation[];
}

function isWithin(root: string, candidate: string): boolean {
  const path = resolve(candidate);
  const prefix = root.endsWith(sep) ? root : `${root}${sep}`;
  return path === root || path.startsWith(prefix);
}

async function nearestExistingPath(path: string): Promise<string> {
  let current = path;
  while (true) {
    try {
      return await realpath(current);
    } catch {
      const parent = dirname(current);
      if (parent === current)
        throw new RuntimeSecurityError("Path does not have an existing parent");
      current = parent;
    }
  }
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
  maxStdoutBytes: number,
  maxStderrBytes: number,
  signal: AbortSignal,
): Promise<{
  stdout: string;
  stderr: string;
  exitCode: number | null;
  status: RuntimeEvidence["status"];
  stdoutTruncated: boolean;
  stderrTruncated: boolean;
}> {
  return new Promise((resolvePromise) => {
    const executable = command[0];
    if (!executable) {
      resolvePromise({
        stdout: "",
        stderr: "No command supplied",
        exitCode: null,
        status: "failed",
        stdoutTruncated: false,
        stderrTruncated: false,
      });
      return;
    }
    const child = spawn(executable, command.slice(1), {
      cwd,
      shell: false,
      windowsHide: true,
      detached: process.platform !== "win32",
    });
    let stdout = "";
    let stderr = "";
    let stdoutTruncated = false;
    let stderrTruncated = false;
    let timedOut = false;
    let cancelled = false;
    const terminate = () => {
      if (process.platform === "win32" && child.pid) {
        spawn("taskkill", ["/pid", String(child.pid), "/t", "/f"], {
          windowsHide: true,
        });
      } else if (child.pid) {
        try {
          process.kill(-child.pid, "SIGTERM");
        } catch {
          child.kill("SIGTERM");
        }
      }
    };
    const timer = setTimeout(() => {
      timedOut = true;
      terminate();
    }, timeoutMs);
    const onAbort = () => {
      cancelled = true;
      terminate();
    };
    signal.addEventListener("abort", onAbort, { once: true });
    child.stdout.on("data", (chunk: Buffer) => {
      const next = `${stdout}${chunk.toString()}`;
      if (Buffer.byteLength(next) > maxStdoutBytes) stdoutTruncated = true;
      stdout = next.slice(0, maxStdoutBytes);
      if (stdoutTruncated) terminate();
    });
    child.stderr.on("data", (chunk: Buffer) => {
      const next = `${stderr}${chunk.toString()}`;
      if (Buffer.byteLength(next) > maxStderrBytes) stderrTruncated = true;
      stderr = next.slice(0, maxStderrBytes);
      if (stderrTruncated) terminate();
    });
    child.on("error", (error: Error) => {
      clearTimeout(timer);
      signal.removeEventListener("abort", onAbort);
      resolvePromise({
        stdout,
        stderr: `${stderr}${error.message}`,
        exitCode: null,
        status: cancelled ? "rejected" : "failed",
        stdoutTruncated,
        stderrTruncated,
      });
    });
    child.on("close", (exitCode) => {
      clearTimeout(timer);
      signal.removeEventListener("abort", onAbort);
      resolvePromise({
        stdout,
        stderr,
        exitCode,
        status: cancelled
          ? "rejected"
          : timedOut
            ? "timed_out"
            : exitCode === 0
              ? "succeeded"
              : "failed",
        stdoutTruncated,
        stderrTruncated,
      });
    });
  });
}

export class LocalRuntime {
  private readonly repositories = new Map<string, RuntimeRepository>();
  private readonly policy: Required<
    Pick<
      RuntimePolicy,
      | "maxReadBytes"
      | "maxWriteBytes"
      | "maxSearchResults"
      | "defaultTimeoutMs"
      | "maxStdoutBytes"
      | "maxStderrBytes"
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
      maxStdoutBytes: policy.maxStdoutBytes ?? 512_000,
      maxStderrBytes: policy.maxStderrBytes ?? 512_000,
    };
    for (const repository of policy.repositories) {
      const root = resolve(repository.root);
      if (this.repositories.has(repository.id)) {
        throw new RuntimeSecurityError(`Duplicate repository ${repository.id}`);
      }
      this.repositories.set(repository.id, {
        ...repository,
        root: realpathSync(root),
      });
    }
  }

  private readonly activeOperations = new Map<string, AbortController>();

  cancel(requestId: string): boolean {
    const controller = this.activeOperations.get(requestId);
    if (!controller) return false;
    controller.abort();
    return true;
  }

  async execute(request: RuntimeOperation): Promise<RuntimeEvidence> {
    const startedAt = new Date();
    const repository = this.repositories.get(request.repositoryId);
    const controller = new AbortController();
    this.activeOperations.set(request.requestId, controller);
    try {
      if (!repository) {
        throw new RuntimeSecurityError("Repository is not registered");
      }
      this.authorize(request, startedAt);
      const result = await this.perform(request, repository, controller.signal);
      return this.evidence(
        request,
        repository,
        startedAt,
        result.status,
        result.summary,
        result.content,
        result.exitCode,
        result.command,
        result.stdoutTruncated,
        result.stderrTruncated,
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
        false,
        false,
      );
    } finally {
      this.activeOperations.delete(request.requestId);
    }
  }

  private authorize(request: RuntimeOperation, now: Date): void {
    if (
      request.organizationId !== request.approval.organizationId ||
      request.projectId !== request.approval.projectId ||
      request.runId !== request.approval.runId ||
      request.taskId !== request.approval.taskId
    ) {
      throw new RuntimeSecurityError(
        "Runtime request is outside its approval scope",
      );
    }
    if (!request.approval.operationKinds.includes(request.kind)) {
      throw new RuntimeSecurityError(
        "Operation is not covered by the approval",
      );
    }
    if (Date.parse(request.approval.expiresAt) <= now.getTime()) {
      throw new RuntimeSecurityError("Runtime approval has expired");
    }
  }

  private async resolvePath(
    repository: RuntimeRepository,
    path = ".",
  ): Promise<string> {
    if (isAbsolute(path)) {
      throw new RuntimeSecurityError("Absolute paths are not allowed");
    }
    const candidate = resolve(repository.root, path);
    if (!isWithin(repository.root, candidate)) {
      throw new RuntimeSecurityError("Path escapes the registered repository");
    }
    const existing = await realpath(candidate).catch(() => null);
    if (existing !== null) {
      if (!isWithin(repository.root, existing)) {
        throw new RuntimeSecurityError(
          "Path escapes the registered repository through a symlink",
        );
      }
      return existing;
    }
    const parent = await nearestExistingPath(dirname(candidate));
    if (!isWithin(repository.root, parent)) {
      throw new RuntimeSecurityError(
        "Path escapes the registered repository through a symlink",
      );
    }
    return candidate;
  }

  private async perform(
    request: RuntimeOperation,
    repository: RuntimeRepository,
    signal: AbortSignal,
  ): Promise<{
    status: RuntimeEvidence["status"];
    summary: string;
    content: string;
    exitCode: number | null;
    command: readonly string[] | null;
    stdoutTruncated?: boolean;
    stderrTruncated?: boolean;
  }> {
    switch (request.kind) {
      case "read_file": {
        const path = await this.resolvePath(repository, request.path);
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
        const start = await this.resolvePath(repository, request.path);
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
          const safeFile = await this.resolvePath(repository, file).catch(
            () => null,
          );
          if (safeFile === null) continue;
          const content = await readFile(safeFile, "utf8").catch(() => null);
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
        const path = await this.resolvePath(repository, request.path);
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
      case "patch_file": {
        const path = await this.resolvePath(repository, request.path);
        const current = await readFile(path, "utf8").catch(() => null);
        if (current === null)
          throw new RuntimeSecurityError("File does not exist");
        if (
          request.expectedDigest &&
          digest(current) !== request.expectedDigest
        ) {
          throw new RuntimeSecurityError("Expected file digest does not match");
        }
        let content = current;
        for (const patch of request.patches) {
          const occurrences = content.split(patch.oldText).length - 1;
          const maxReplacements = patch.maxReplacements ?? 1;
          if (occurrences === 0) {
            throw new RuntimeSecurityError("Patch text was not found");
          }
          if (occurrences > maxReplacements) {
            throw new RuntimeSecurityError("Patch text is ambiguous");
          }
          content = content.replace(patch.oldText, patch.newText);
        }
        if (Buffer.byteLength(content) > this.policy.maxWriteBytes) {
          throw new RuntimeSecurityError("File exceeds the write limit");
        }
        await writeFile(path, content, "utf8");
        return {
          status: "succeeded",
          summary: `Patched ${relative(repository.root, path)}`,
          content: JSON.stringify({
            path: relative(repository.root, path),
            digest: digest(content),
            bytes: Buffer.byteLength(content),
          }),
          exitCode: 0,
          command: null,
        };
      }
      case "delete_file": {
        const path = await this.resolvePath(repository, request.path);
        const current = await readFile(path, "utf8").catch(() => null);
        if (current === null)
          throw new RuntimeSecurityError("File does not exist");
        if (
          request.expectedDigest &&
          digest(current) !== request.expectedDigest
        ) {
          throw new RuntimeSecurityError("Expected file digest does not match");
        }
        await unlink(path);
        return {
          status: "succeeded",
          summary: `Deleted ${relative(repository.root, path)}`,
          content: JSON.stringify({ path: relative(repository.root, path) }),
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
        const cwd = await this.resolvePath(repository, request.path);
        const result = await runCommand(
          args,
          cwd,
          this.policy.defaultTimeoutMs,
          this.policy.maxStdoutBytes,
          this.policy.maxStderrBytes,
          signal,
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
        const cwd = await this.resolvePath(repository, request.cwd);
        const result = await runCommand(
          request.command,
          cwd,
          request.timeoutMs ?? this.policy.defaultTimeoutMs,
          this.policy.maxStdoutBytes,
          this.policy.maxStderrBytes,
          signal,
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
    stdoutTruncated = false,
    stderrTruncated = false,
  ): RuntimeEvidence {
    const finishedAt = new Date();
    const contentDigest = digest(content);
    return {
      evidenceId: idFor(request.requestId, contentDigest),
      requestId: request.requestId,
      organizationId: request.organizationId,
      projectId: request.projectId,
      runId: request.runId,
      taskId: request.taskId,
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
      stdoutTruncated,
      stderrTruncated,
    };
  }
}

export class OutboundRuntimeSession {
  private readonly workers = new Map<string, LocalWorkerExecutor>();

  constructor(
    private readonly runtime: LocalRuntime,
    private readonly transport: RuntimeTransport,
    workers: readonly LocalWorkerExecutor[] = [],
  ) {
    for (const worker of workers)
      this.workers.set(worker.descriptor.workerId, worker);
  }

  async run(): Promise<void> {
    await this.transport.connect();
    await this.transport.announceWorkers?.(
      [...this.workers.values()].map((worker) => worker.descriptor),
    );
    const replay = new Map<string, RuntimeEvidence>();
    const workerReplay = new Map<string, WorkerExecutionResult>();
    try {
      while (true) {
        let received = false;
        try {
          for await (const rawRequest of this.transport.receive()) {
            received = true;
            if (
              typeof rawRequest === "object" &&
              "type" in rawRequest &&
              rawRequest.type === "cancel"
            ) {
              this.runtime.cancel(rawRequest.requestId);
              continue;
            }
            if (isRuntimeWorkerExecutionRequest(rawRequest)) {
              const worker = this.workers.get(rawRequest.request.workerId);
              const previous = workerReplay.get(rawRequest.request.requestId);
              const result =
                previous ??
                (worker
                  ? await worker.execute(rawRequest.request).catch((error) => ({
                      status: "failed" as const,
                      output: null,
                      rawOutput: null,
                      usage: { inputTokens: null, outputTokens: null },
                      evidenceArtifactIds: [],
                      error: {
                        code: "worker_execution_failed",
                        message:
                          error instanceof Error
                            ? error.message
                            : "Local worker execution failed",
                        retryable: true,
                      },
                    }))
                  : {
                      status: "failed" as const,
                      output: null,
                      rawOutput: null,
                      usage: { inputTokens: null, outputTokens: null },
                      evidenceArtifactIds: [],
                      error: {
                        code: "worker_not_found",
                        message: `Local worker ${rawRequest.request.workerId} is not registered`,
                        retryable: false,
                      },
                    });
              const workerResult = {
                type: "worker_result",
                requestId: rawRequest.request.requestId,
                result,
              } satisfies RuntimeWorkerExecutionResult;
              workerReplay.set(rawRequest.request.requestId, result);
              await this.transport.sendWorkerResult?.(workerResult);
              continue;
            }
            const request = parseRuntimeOperation(rawRequest);
            const previous = replay.get(request.requestId);
            const evidence = previous ?? (await this.runtime.execute(request));
            replay.set(request.requestId, evidence);
            await this.transport.send(evidence);
            await this.transport.acknowledge?.(request.requestId);
          }
        } catch (error) {
          if (!this.transport.reconnect) throw error;
        }
        if (!this.transport.reconnect || !received) break;
        await this.transport.disconnect?.();
        await this.transport.reconnect();
      }
    } finally {
      await this.transport.disconnect?.();
    }
  }
}

export { CodexLocalAgent } from "./codex.js";
export type {
  CodexChild,
  CodexLocalAgentOptions,
  CodexSpawn,
} from "./codex.js";
export { ClaudeCodeLocalAgent } from "./claude.js";
export type { ClaudeCodeLocalAgentOptions } from "./claude.js";
export { GitWorkspaceManager } from "./git-workspaces.js";
export type {
  GitCommandResult,
  GitRunner,
  GitWorkspace,
  GitWorkspaceManagerOptions,
} from "./git-workspaces.js";
export { GitWorkspaceError } from "./git-workspaces.js";
