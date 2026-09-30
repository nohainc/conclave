import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  access,
  constants,
  mkdir,
  readFile,
  rm,
  rename,
  writeFile,
} from "node:fs/promises";
import { existsSync, readFileSync } from "node:fs";
import { delimiter, dirname, join, isAbsolute } from "node:path";
import { createInterface } from "node:readline";

const DEFAULT_STDOUT_LIMIT = 8 * 1024 * 1024;
const DEFAULT_STDERR_LIMIT = 1024 * 1024;
const DEFAULT_COMMAND_TIMEOUT_MS = 10_000;
const DEFAULT_KILL_GRACE_MS = 1_000;
const BASE_CLI_ENVIRONMENT = [
  "PATH",
  "HOME",
  "USERPROFILE",
  "TMPDIR",
  "TMP",
  "TEMP",
  "SystemRoot",
  "LANG",
  "LC_ALL",
  "LC_CTYPE",
  "SSL_CERT_FILE",
  "SSL_CERT_DIR",
  "NO_COLOR",
  "TERM",
];

export function buildCliEnvironment({
  passthrough = [],
  source = process.env,
  extraPathDirectories = [],
} = {}) {
  const environment = {};
  for (const name of new Set([...BASE_CLI_ENVIRONMENT, ...passthrough])) {
    if (typeof source[name] === "string") environment[name] = source[name];
  }
  const home = environment.HOME || environment.USERPROFILE;
  const pathEntries = [
    ...(environment.PATH ?? "").split(delimiter),
    ...(home
      ? [
          join(home, ".local", "bin"),
          join(home, ".npm-global", "bin"),
          join(home, "bin"),
        ]
      : []),
    ...(process.platform === "win32"
      ? []
      : ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]),
    ...extraPathDirectories,
  ];
  environment.PATH = [...new Set(pathEntries.filter(Boolean))].join(delimiter);
  return environment;
}

export function readPackageEnvironmentPolicy(adapterUrl) {
  const installedManifest = new URL("../manifest.json", adapterUrl);
  const sourceManifest = new URL("../manifest.template.json", adapterUrl);
  const manifestUrl = existsSync(installedManifest)
    ? installedManifest
    : sourceManifest;
  const manifest = JSON.parse(readFileSync(manifestUrl, "utf8"));
  const policy = manifest.environmentPolicy ?? {};
  const providerCliPassthrough = policy.providerCliPassthrough ?? [];
  if (
    !Array.isArray(providerCliPassthrough) ||
    providerCliPassthrough.some(
      (name) => typeof name !== "string" || !/^[A-Z_][A-Z0-9_]*$/.test(name),
    )
  ) {
    throw new TypeError("Worker Package environment policy is invalid.");
  }
  return { providerCliPassthrough };
}

export async function discoverExecutable(
  executable,
  searchPath = process.env.PATH,
  knownDirectories = [],
) {
  if (typeof executable !== "string" || !executable.trim()) {
    throw new TypeError("CLI executable must be a non-empty string.");
  }
  const hasPath =
    isAbsolute(executable) ||
    executable.includes("/") ||
    executable.includes("\\");
  const names =
    process.platform === "win32" && !/\.[^\\/]+$/.test(executable)
      ? [
          executable,
          ...(process.env.PATHEXT ?? ".EXE;.CMD;.BAT;.COM")
            .split(";")
            .map((extension) => `${executable}${extension.toLowerCase()}`),
        ]
      : [executable];
  const candidates = hasPath
    ? names.map((name) =>
        executable.endsWith(name)
          ? executable
          : `${executable}${name.slice(executable.length)}`,
      )
    : [
        ...(searchPath ?? "").split(delimiter).filter(Boolean),
        ...knownDirectories,
      ]
        .filter(Boolean)
        .flatMap((directory) => names.map((name) => join(directory, name)));
  const accessMode =
    process.platform === "win32" ? constants.F_OK : constants.X_OK;
  for (const candidate of candidates) {
    try {
      await access(candidate, accessMode);
      return candidate;
    } catch {
      // Continue through PATH entries. The final ENOENT is normalized below.
    }
  }
  const error = new Error(`Executable not found: ${executable}`);
  error.code = "ENOENT";
  throw error;
}

export class CliToolRunner {
  constructor({
    executable,
    env,
    cwd = process.cwd(),
    defaultTimeoutMs = DEFAULT_COMMAND_TIMEOUT_MS,
    killGraceMs = DEFAULT_KILL_GRACE_MS,
    packageId,
    knownDirectories = [],
  }) {
    if (!executable) throw new TypeError("CLI executable is required.");
    this.executable = executable;
    this.env = env ?? {};
    this.cwd = cwd;
    this.defaultTimeoutMs = defaultTimeoutMs;
    this.killGraceMs = killGraceMs;
    this.packageId = packageId;
    this.knownDirectories = knownDirectories;
    this.resolvedExecutable = null;
  }

  async resolveExecutable() {
    if (this.resolvedExecutable) return this.resolvedExecutable;
    const cacheFile = this.#executableCacheFile();
    if (cacheFile) {
      const cached = await readCachedExecutable(cacheFile);
      if (cached && (await executableExists(cached))) {
        this.resolvedExecutable = cached;
        return cached;
      }
    }
    this.resolvedExecutable = await discoverExecutable(
      this.executable,
      this.env.PATH,
      this.knownDirectories,
    );
    if (cacheFile)
      await writeCachedExecutable(cacheFile, this.resolvedExecutable);
    return this.resolvedExecutable;
  }

  #executableCacheFile() {
    if (!this.packageId) return null;
    const safePackageId = this.packageId.replace(/[^a-zA-Z0-9._-]/g, "_");
    const home = this.env.HOME || this.env.USERPROFILE;
    if (!home) return null;
    const base =
      process.platform === "win32"
        ? join(home, "AppData", "Local", "Conclave", "WorkerPackages")
        : process.platform === "darwin"
          ? join(home, "Library", "Caches", "Conclave", "WorkerPackages")
          : join(
              this.env.XDG_CACHE_HOME || join(home, ".cache"),
              "conclave",
              "worker-packages",
            );
    return join(base, safePackageId, "cli-path.json");
  }

  async runCommand(args, options = {}) {
    const stdoutChunks = [];
    const stderrChunks = [];
    let stdoutBytes = 0;
    let stderrBytes = 0;
    const stdoutLimit = options.stdoutLimit ?? DEFAULT_STDOUT_LIMIT;
    const stderrLimit = options.stderrLimit ?? DEFAULT_STDERR_LIMIT;

    const result = await this.#run(args, {
      ...options,
      onStdout: (chunk, child, controls) => {
        stdoutBytes += chunk.length;
        if (stdoutBytes > stdoutLimit) {
          controls.fail(
            "stdout_limit",
            "CLI output exceeded the configured limit.",
          );
          return;
        }
        stdoutChunks.push(chunk);
        options.onStdout?.(chunk, child);
      },
      onStderr: (chunk, child, controls) => {
        stderrBytes += chunk.length;
        if (stderrBytes > stderrLimit) {
          controls.fail(
            "stderr_limit",
            "CLI diagnostics exceeded the configured limit.",
          );
          return;
        }
        stderrChunks.push(chunk);
        options.onStderr?.(chunk, child);
      },
    });
    return {
      ...result,
      stdout: Buffer.concat(stdoutChunks).toString("utf8"),
      stderr: Buffer.concat(stderrChunks).toString("utf8"),
    };
  }

  async runStream(args, { onLine, ...options } = {}) {
    if (typeof onLine !== "function") {
      throw new TypeError("runStream requires an onLine callback.");
    }
    let stdoutBytes = 0;
    let stderrBytes = 0;
    let stderr = "";
    const stdoutLimit = options.stdoutLimit ?? DEFAULT_STDOUT_LIMIT;
    const stderrLimit = options.stderrLimit ?? DEFAULT_STDERR_LIMIT;
    let lineReader;
    try {
      const result = await this.#run(args, {
        ...options,
        requireSuccess: options.requireSuccess ?? false,
        onSpawn: (child, controls) => {
          lineReader = createInterface({
            input: child.stdout,
            crlfDelay: Infinity,
          });
          lineReader.on("line", (line) => {
            if (controls.failed) return;
            try {
              onLine(line);
            } catch (error) {
              controls.fail(
                error?.code ?? "stream_parse_error",
                error?.message ?? "CLI stream parsing failed.",
              );
            }
          });
        },
        onStdout: (chunk, child, controls) => {
          stdoutBytes += chunk.length;
          if (stdoutBytes > stdoutLimit) {
            controls.fail(
              "stdout_limit",
              "CLI output exceeded the configured limit.",
            );
            return;
          }
          options.onStdout?.(chunk, child);
        },
        onStderr: (chunk, child, controls) => {
          stderrBytes += chunk.length;
          if (stderrBytes > stderrLimit) {
            controls.fail(
              "stderr_limit",
              "CLI diagnostics exceeded the configured limit.",
            );
            return;
          }
          if (
            Buffer.byteLength(stderr, "utf8") <
            (options.stderrCaptureBytes ?? 2048)
          ) {
            stderr = Buffer.concat([Buffer.from(stderr, "utf8"), chunk])
              .subarray(0, options.stderrCaptureBytes ?? 2048)
              .toString("utf8");
          }
          options.onStderr?.(chunk, child);
        },
      });
      return { ...result, stderr };
    } catch (error) {
      if (error.code === "CLI_EXIT_NONZERO" && stderr) error.message = stderr;
      error.stderr = stderr;
      throw error;
    } finally {
      lineReader?.close();
    }
  }

  async #run(args, options) {
    const executable = await this.resolveExecutable();
    const timeoutMs = effectiveTimeout(
      options.timeoutMs ?? this.defaultTimeoutMs,
      options.deadlineAt,
    );
    const child = spawn(executable, args, {
      cwd: options.cwd ?? this.cwd,
      env: options.env ?? this.env,
      stdio: [options.stdin == null ? "ignore" : "pipe", "pipe", "pipe"],
      windowsHide: true,
      // Give each CLI invocation an isolated process group so timeouts and
      // Workspace cancellation can stop provider-created grandchildren too.
      detached: process.platform !== "win32",
    });
    let settled = false;
    let failure = null;
    let cleanupPromise = null;
    let timeout;
    let abortHandler;
    const controls = {
      get failed() {
        return failure !== null;
      },
      fail(code, message) {
        if (failure) return;
        failure = Object.assign(new Error(message), { code });
        cleanupPromise = terminateProcessTree(
          child,
          options.killGraceMs ?? thisRunner.killGraceMs,
        );
      },
    };
    const thisRunner = this;

    const cleanup = () => {
      clearTimeout(timeout);
      if (options.signal && abortHandler)
        options.signal.removeEventListener("abort", abortHandler);
    };
    const closePromise = new Promise((resolve, reject) => {
      child.once("error", reject);
      child.once("close", (code, signal) => resolve({ code, signal }));
    });
    child.stdout.on("data", (chunk) =>
      options.onStdout?.(chunk, child, controls),
    );
    child.stderr.on("data", (chunk) =>
      options.onStderr?.(chunk, child, controls),
    );
    options.onSpawn?.(child, controls);
    if (options.stdin != null) child.stdin.end(options.stdin);
    if (Number.isFinite(timeoutMs) && timeoutMs >= 0) {
      timeout = setTimeout(
        () => controls.fail("timeout", "CLI command timed out."),
        timeoutMs,
      );
      timeout.unref?.();
    }
    if (options.signal) {
      abortHandler = () =>
        controls.fail("cancelled", "CLI command was cancelled.");
      if (options.signal.aborted) abortHandler();
      else
        options.signal.addEventListener("abort", abortHandler, { once: true });
    }

    try {
      const closed = await closePromise;
      settled = true;
      if (cleanupPromise) await cleanupPromise;
      if (failure) throw failure;
      if (options.requireSuccess !== false && closed.code !== 0) {
        const error = new Error(
          `CLI exited with code ${closed.code ?? "unknown"}.`,
        );
        error.code = "CLI_EXIT_NONZERO";
        error.exitCode = closed.code;
        throw error;
      }
      return { exitCode: closed.code, signal: closed.signal };
    } catch (error) {
      if (!settled && child.exitCode === null) {
        cleanupPromise ??= terminateProcessTree(
          child,
          options.killGraceMs ?? this.killGraceMs,
        );
        await cleanupPromise;
      }
      throw error;
    } finally {
      cleanup();
    }
  }
}

// Stores package-private provider session IDs under opaque logical session
// keys. Provider session IDs never need to cross the Local Worker Protocol.
export class CliSessionStore {
  constructor({ packageId, env = process.env }) {
    if (typeof packageId !== "string" || !packageId.trim()) {
      throw new TypeError(
        "A package ID is required for local session storage.",
      );
    }
    this.packageId = packageId.replace(/[^a-zA-Z0-9._-]/g, "_");
    this.env = env;
  }

  async get(sessionKey) {
    const file = this.#file(sessionKey);
    try {
      const stored = JSON.parse(await readFile(file, "utf8"));
      if (
        stored?.version !== 1 ||
        stored.keyHash !== this.#keyHash(sessionKey) ||
        typeof stored.providerSessionId !== "string" ||
        !stored.providerSessionId.trim() ||
        stored.providerSessionId.length > 256
      ) {
        throw new Error("Stored local session state is invalid.");
      }
      return stored.providerSessionId;
    } catch (error) {
      if (error?.code === "ENOENT") return null;
      throw error;
    }
  }

  async set(sessionKey, providerSessionId) {
    if (
      typeof providerSessionId !== "string" ||
      !providerSessionId.trim() ||
      providerSessionId.length > 256
    ) {
      throw new TypeError("Provider session ID is invalid.");
    }
    const file = this.#file(sessionKey);
    await mkdir(dirname(file), { recursive: true, mode: 0o700 });
    const temporary = `${file}.${process.pid}.${randomUUID()}.tmp`;
    try {
      await writeFile(
        temporary,
        JSON.stringify({
          version: 1,
          keyHash: this.#keyHash(sessionKey),
          providerSessionId,
        }),
        { mode: 0o600, flag: "wx" },
      );
      await rename(temporary, file);
    } finally {
      await rm(temporary, { force: true }).catch(() => {});
    }
  }

  #file(sessionKey) {
    if (
      typeof sessionKey !== "string" ||
      !sessionKey.trim() ||
      sessionKey.length > 256
    ) {
      throw new TypeError("Logical session key is invalid.");
    }
    const stateHome = this.env.CONCLAVE_WORKER_STATE_DIR;
    if (typeof stateHome !== "string" || !isAbsolute(stateHome)) {
      throw new Error(
        "Workspace did not provide a private Worker state directory.",
      );
    }
    return join(
      stateHome,
      this.packageId,
      "sessions",
      `${this.#keyHash(sessionKey)}.json`,
    );
  }

  #keyHash(sessionKey) {
    return createHash("sha256").update(sessionKey).digest("hex");
  }
}

async function executableExists(path) {
  try {
    await access(
      path,
      process.platform === "win32" ? constants.F_OK : constants.X_OK,
    );
    return true;
  } catch {
    return false;
  }
}

async function readCachedExecutable(cacheFile) {
  try {
    const value = JSON.parse(await readFile(cacheFile, "utf8"));
    return typeof value?.executable === "string" && isAbsolute(value.executable)
      ? value.executable
      : null;
  } catch {
    return null;
  }
}

async function writeCachedExecutable(cacheFile, executable) {
  const temporary = `${cacheFile}.${process.pid}.tmp`;
  try {
    await mkdir(dirname(cacheFile), { recursive: true, mode: 0o700 });
    await writeFile(temporary, JSON.stringify({ executable }), { mode: 0o600 });
    if (process.platform === "win32") await rm(cacheFile, { force: true });
    await rename(temporary, cacheFile);
  } catch {
    // A read-only home or concurrent package cleanup must not block discovery.
    await rm(temporary, { force: true }).catch(() => {});
  }
}

function effectiveTimeout(timeoutMs, deadlineAt) {
  if (deadlineAt == null) return timeoutMs;
  const remainingMs = Math.max(0, deadlineAt - Date.now());
  return Math.min(timeoutMs, remainingMs);
}

async function terminateProcessTree(child, graceMs) {
  if (process.platform !== "win32" && child.pid) {
    try {
      process.kill(-child.pid, "SIGTERM");
    } catch {
      child.kill("SIGTERM");
    }
  } else {
    child.kill("SIGTERM");
  }
  await new Promise((resolve) => setTimeout(resolve, graceMs));
  // Provider CLIs may leave grandchildren holding the package pipes open.
  // Keep them in Workspace's process group and clean their subtree here first.
  if (process.platform === "win32" && child.pid) {
    const killer = spawn("taskkill", ["/PID", String(child.pid), "/T", "/F"], {
      stdio: "ignore",
      windowsHide: true,
    });
    killer.once("error", () => child.kill("SIGKILL"));
  } else {
    try {
      process.kill(-child.pid, "SIGKILL");
    } catch {
      const descendants = await processDescendants(child.pid);
      const currentDescendants = await processDescendants(child.pid);
      const pids = [
        ...new Set([...descendants, ...currentDescendants]),
      ].reverse();
      for (const pid of pids) {
        try {
          process.kill(pid, "SIGKILL");
        } catch {
          // A child may have exited between discovery and the signal.
        }
      }
      try {
        child.kill("SIGKILL");
      } catch {
        // The direct child may already have exited.
      }
    }
  }
}

async function processDescendants(rootPid) {
  if (!rootPid || process.platform === "win32") return [];
  const discovered = new Set();
  const pending = [rootPid];
  while (pending.length && discovered.size < 1024) {
    const parentPid = pending.pop();
    const children = await new Promise((resolve) => {
      const finder = spawn("pgrep", ["-P", String(parentPid)], {
        stdio: ["ignore", "pipe", "ignore"],
      });
      let output = "";
      finder.stdout.setEncoding("utf8");
      finder.stdout.on("data", (chunk) => (output += chunk));
      finder.once("error", () => resolve([]));
      finder.once("close", () =>
        resolve(
          output
            .split(/\s+/)
            .map(Number)
            .filter((pid) => Number.isInteger(pid) && pid > 0),
        ),
      );
    });
    for (const childPid of children) {
      if (!discovered.has(childPid)) {
        discovered.add(childPid);
        pending.push(childPid);
      }
    }
  }
  return [...discovered];
}
