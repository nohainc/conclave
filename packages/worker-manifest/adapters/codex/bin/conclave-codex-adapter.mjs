#!/usr/bin/env node
import { existsSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
const sharedRuntime = existsSync(
  new URL("../../shared/cli_tool_runner.mjs", import.meta.url),
)
  ? new URL("../../shared/cli_tool_runner.mjs", import.meta.url)
  : new URL("../lib/cli_tool_runner.mjs", import.meta.url);
const {
  buildCliEnvironment,
  CliSessionStore,
  CliToolRunner,
  readPackageEnvironmentPolicy,
} = await import(sharedRuntime.href);

const protocolVersion = "2.5";
const maxPromptBytes = 512 * 1024;
let adapterVersion = "1.0.0";
let currentAssignment = null;
let activeCliController = null;
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    process.exitCode = signal === "SIGINT" ? 130 : 143;
    activeCliController?.abort();
    process.stdin.destroy();
  });
}
const cliExecutable = "codex";
const homeDirectory = process.env.HOME || process.env.USERPROFILE;
const environmentPolicy = readPackageEnvironmentPolicy(import.meta.url);
const cliEnvironment = buildCliEnvironment({
  passthrough: environmentPolicy.providerCliPassthrough,
});
const cliTool = new CliToolRunner({
  executable: cliExecutable,
  env: cliEnvironment,
  packageId: "codex",
  knownDirectories: homeDirectory
    ? [
        join(homeDirectory, ".local", "bin"),
        join(homeDirectory, ".npm-global", "bin"),
        join(homeDirectory, ".npm", "bin"),
        join(homeDirectory, ".volta", "bin"),
        join(homeDirectory, ".bun", "bin"),
      ]
    : [],
});
const cliSessions = new CliSessionStore({
  packageId: "codex",
  env: process.env,
});

function classifyProviderError(value) {
  const diagnostic = typeof value === "string" ? value : "";
  const normalized = diagnostic.toLowerCase();
  if (/\b(cancelled|canceled|user interrupted)\b/.test(normalized))
    return "cancelled";
  if (/\b(timeout|timed out|deadline exceeded)\b/.test(normalized))
    return "timeout";
  if (/\bunsupported (cli|tool) version\b/.test(normalized))
    return "unsupported_cli_version";
  if (
    /\b(unauthori[sz]ed|authentication required|not logged in|log in|sign in|token expired|invalid api key)\b/.test(
      normalized,
    )
  )
    return "authentication_required";
  if (
    /\b(model (not found|unsupported|not supported|is unavailable)|unsupported model|unknown model|invalid model)\b/.test(
      normalized,
    )
  )
    return "model_not_supported";
  if (
    /\b(quota|usage limit|rate limit|too many requests|\b429\b)\b/.test(
      normalized,
    )
  )
    return "quota_exhausted";
  if (
    /\b(server overloaded|service unavailable|provider unavailable|connection refused|network error|\b5\d\d\b)\b/.test(
      normalized,
    )
  )
    return "provider_unavailable";
  if (
    /\b(permission denied|approval denied|tool.*(denied|rejected)|sandbox.*(denied|blocked))\b/.test(
      normalized,
    )
  )
    return "permission_denied";
  return "execution_failed";
}

function safeFailure(code) {
  const messages = {
    cli_not_found: "The required local CLI could not be found.",
    worker_not_ready: "The selected Worker is not ready on its Workspace.",
    authentication_required:
      "Sign in to the configured provider on this computer.",
    unsupported_cli_version:
      "The installed local CLI version is not supported.",
    model_not_supported: "The selected model is not supported by this Worker.",
    permission_denied:
      "A local permission required for this assignment was denied.",
    quota_exhausted: "The provider's usage limit has been reached.",
    provider_unavailable: "The provider is temporarily unavailable.",
    timeout: "The assignment exceeded its time limit.",
    cancelled: "The assignment was cancelled.",
    internal_adapter_error: "The local Worker integration needs attention.",
    execution_test_failed: "The live probe did not complete successfully.",
    execution_failed: "The assignment could not be completed.",
  };
  return messages[code] || messages.execution_failed;
}

function send(type, fields = {}) {
  process.stdout.write(
    `${JSON.stringify({ type, protocolVersion, ...fields })}\n`,
  );
}

function boundedText(value, maxBytes) {
  const text = typeof value === "string" ? value : "";
  const bytes = Buffer.from(text, "utf8");
  if (bytes.byteLength <= maxBytes) return text;
  return bytes.subarray(0, maxBytes).toString("utf8");
}

function cliArgs(model, providerSessionId, durableSession = false) {
  const args = [
    "--ask-for-approval",
    "never",
    "--sandbox",
    "workspace-write",
    "exec",
    "--json",
    "--color",
    "never",
    "--skip-git-repo-check",
    "--cd",
    process.cwd(),
  ];
  if (model) args.push("--model", model);
  if (providerSessionId) {
    args.push("resume", providerSessionId);
  } else if (!durableSession) {
    args.push("--ephemeral");
  }
  args.push("-");
  return args;
}

const CLI_CLEANUP_GRACE_MS = 1500;

function sessionResumeError() {
  return Object.assign(
    new Error("Codex did not resume the requested local session."),
    { code: "execution_failed" },
  );
}

async function runCli(
  prompt,
  model,
  requestId,
  assignmentId,
  timeoutMs,
  sessionPolicy = "stateless",
  sessionKey = null,
) {
  if (sessionPolicy === "durable_session" && !sessionKey) {
    throw new Error("Durable sessions require a logical session key.");
  }
  const deadlineAt = Date.now() + timeoutMs;
  const priorSessionId = sessionKey ? await cliSessions.get(sessionKey) : null;
  const cliDeadlineAt = deadlineAt - CLI_CLEANUP_GRACE_MS;
  const controller = new AbortController();
  activeCliController = controller;
  let finalMessage = "";
  let observedSessionId = null;
  let turnCompleted = false;
  let cliError = null;
  const result = await cliTool
    .runStream(
      cliArgs(model, priorSessionId, sessionPolicy === "durable_session"),
      {
        stdin: prompt,
        timeoutMs: Number.POSITIVE_INFINITY,
        deadlineAt: cliDeadlineAt,
        stdoutLimit: 8 * 1024 * 1024,
        stderrLimit: 1024 * 1024,
        signal: controller.signal,
        onLine(line) {
          if (cliError) return;
          let event;
          try {
            event = JSON.parse(line);
          } catch {
            throw new Error("Codex emitted a malformed JSON event.");
          }
          if (
            event.type === "item.completed" &&
            event.item?.type === "agent_message"
          ) {
            finalMessage = boundedText(event.item.text, 512 * 1024);
          } else if (event.type === "turn.started") {
            if (requestId)
              send("progress", {
                requestId,
                assignmentId,
                message: "Codex is working on the Workstream assignment.",
              });
          } else if (
            ["item.started", "item.updated", "item.completed"].includes(
              event.type,
            ) &&
            ["command_execution", "mcp_tool_call", "web_search_call"].includes(
              event.item?.type,
            )
          ) {
            // Command output may contain repository data or provider diagnostics.
            // Never forward raw tool output as realtime progress.
            if (requestId)
              send("progress", {
                requestId,
                assignmentId,
                message:
                  "Codex is executing a command in the Workstream workspace.",
              });
          } else if (event.type === "turn.completed") {
            turnCompleted = true;
          } else if (event.type === "thread.started") {
            const startedThreadId = event.thread_id;
            if (
              typeof startedThreadId !== "string" ||
              !startedThreadId.trim() ||
              startedThreadId.length > 256
            ) {
              if (sessionPolicy === "durable_session") {
                cliError = "Codex did not report a usable thread ID.";
                throw sessionResumeError();
              }
              return;
            }
            if (observedSessionId && observedSessionId !== startedThreadId) {
              cliError = "Codex reported conflicting thread IDs.";
              throw sessionResumeError();
            }
            observedSessionId = startedThreadId;
            if (priorSessionId && observedSessionId !== priorSessionId) {
              cliError =
                "Codex started a different session instead of resuming.";
              throw sessionResumeError();
            }
          } else if (event.type === "turn.failed") {
            cliError =
              boundedText(event.error?.message, 2048) ||
              "Codex execution failed.";
            throw Object.assign(new Error(cliError), {
              code: classifyProviderError(cliError),
            });
          } else if (event.type === "error") {
            cliError =
              boundedText(event.message || event.error?.message, 2048) ||
              "Codex execution failed.";
            throw Object.assign(new Error(cliError), {
              code: classifyProviderError(cliError),
            });
          }
        },
      },
    )
    .finally(() => {
      if (activeCliController === controller) activeCliController = null;
    });
  if (result.exitCode !== 0 || cliError || !turnCompleted) {
    throw new Error(
      cliError ||
        result.stderr ||
        `Codex exited with code ${result.exitCode} before completing the turn.`,
    );
  }
  if (!finalMessage)
    throw new Error("Codex completed without a final response.");
  if (sessionPolicy === "durable_session" && sessionKey) {
    if (
      !observedSessionId ||
      (priorSessionId && observedSessionId !== priorSessionId)
    ) {
      throw sessionResumeError();
    }
    await cliSessions.set(sessionKey, observedSessionId);
  }
  return finalMessage;
}

async function checkLogin() {
  const result = await cliTool.runCommand(["login", "status"], {
    timeoutMs: 10_000,
    stdoutLimit: 4096,
    stderrLimit: 4096,
    requireSuccess: false,
  });
  return result.exitCode === 0;
}

async function toolVersion() {
  const { exitCode, stdout } = await cliTool.runCommand(["--version"], {
    timeoutMs: 10_000,
    stdoutLimit: 512,
    stderrLimit: 4096,
    requireSuccess: false,
  });
  if (exitCode !== 0) return null;
  const match = stdout.match(/\b(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)\b/);
  return match?.[1] ?? null;
}

async function handle(frame) {
  const requestId = frame.requestId;
  switch (frame.type) {
    case "initialize.request":
      if (frame.workerTypeId !== "codex")
        throw new Error("Unsupported Worker Type.");
      adapterVersion = frame.adapterVersion;
      send("initialize.result", {
        requestId,
        adapterVersion,
        capabilities: ["code", "repository", "shell"],
      });
      break;
    case "probe.request": {
      const mode = frame.mode ?? frame.config?.mode ?? "passive";
      const checks = [];
      let available = false;
      try {
        await cliTool.resolveExecutable();
        available = true;
        checks.push({ id: "cli_discovery", status: "passed" });
      } catch {
        checks.push({
          id: "cli_discovery",
          status: "failed",
          issueCode: "cli_not_found",
          diagnostic: safeFailure("cli_not_found"),
        });
      }
      const detectedVersion = available
        ? await toolVersion().catch(() => null)
        : null;
      if (detectedVersion) {
        checks.push({ id: "tool_version", status: "passed" });
      } else if (available) {
        checks.push({
          id: "tool_version",
          status: "failed",
          issueCode: "unsupported_cli_version",
          diagnostic: safeFailure("unsupported_cli_version"),
        });
      } else {
        checks.push({ id: "tool_version", status: "skipped" });
      }
      let loggedIn = false;
      if (detectedVersion) {
        loggedIn = await checkLogin().catch(() => false);
        checks.push(
          loggedIn
            ? { id: "authentication", status: "passed" }
            : {
                id: "authentication",
                status: "failed",
                issueCode: "authentication_required",
                diagnostic: safeFailure("authentication_required"),
              },
        );
      } else {
        checks.push({ id: "authentication", status: "skipped" });
      }
      const passiveReady = !checks.some((check) => check.status === "failed");
      if (mode === "live" && passiveReady) {
        try {
          const result = await runCli(
            "Reply with exactly the word OK. Do not use tools.",
            null,
            null,
            null,
            30_000,
          );
          checks.push(
            result.trim() === "OK"
              ? { id: "execution", status: "passed" }
              : {
                  id: "execution",
                  status: "failed",
                  issueCode: "execution_test_failed",
                  diagnostic: safeFailure("execution_test_failed"),
                },
          );
        } catch (error) {
          const issueCode =
            error?.code === "ENOENT"
              ? "cli_not_found"
              : classifyProviderError(error?.message);
          checks.push({
            id: "execution",
            status: "failed",
            issueCode,
            diagnostic: safeFailure(issueCode),
          });
        }
      } else if (mode === "live") {
        checks.push({ id: "execution", status: "skipped" });
      }
      const ready = !checks.some((check) => check.status === "failed");
      send("probe.result", {
        requestId,
        ready,
        toolVersion: detectedVersion,
        mode,
        checks,
      });
      break;
    }
    case "execute.request": {
      const sessionPolicy =
        frame.sessionPolicy ??
        (frame.sessionKey === undefined ? "stateless" : "durable_session");
      if (
        !["stateless", "durable_session"].includes(sessionPolicy) ||
        (sessionPolicy === "durable_session" &&
          (frame.protocolVersion !== "2.5" ||
            typeof frame.sessionKey !== "string" ||
            !frame.sessionKey.trim() ||
            frame.sessionKey.length > 256)) ||
        (sessionPolicy === "stateless" && frame.sessionKey !== undefined)
      ) {
        throw new Error("Session policy or logical session key is invalid.");
      }
      const prompt = boundedText(frame.prompt, maxPromptBytes);
      if (Buffer.byteLength(frame.prompt, "utf8") > maxPromptBytes) {
        throw new Error("Assignment prompt exceeded the adapter limit.");
      }
      currentAssignment = frame.assignmentId;
      try {
        const output = await runCli(
          prompt,
          frame.model,
          requestId,
          frame.assignmentId,
          frame.timeoutMs,
          sessionPolicy,
          frame.sessionKey ?? null,
        );
        send("result", {
          requestId,
          assignmentId: frame.assignmentId,
          output,
          artifacts: [],
        });
      } catch (error) {
        const code =
          error?.code === "ENOENT"
            ? "cli_not_found"
            : classifyProviderError(error?.message);
        send("error", {
          requestId,
          assignmentId: frame.assignmentId,
          code,
          message: safeFailure(code),
          retryable: ["provider_unavailable", "timeout"].includes(code),
        });
      } finally {
        currentAssignment = null;
      }
      break;
    }
    default:
      throw new Error("Unsupported adapter request.");
  }
}

const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
for await (const line of input) {
  if (!line.trim()) continue;
  let frame;
  try {
    frame = JSON.parse(line);
    await handle(frame);
  } catch (error) {
    send("error", {
      requestId:
        typeof frame?.requestId === "string"
          ? frame.requestId
          : "adapter-error",
      ...(currentAssignment ? { assignmentId: currentAssignment } : {}),
      code: "internal_adapter_error",
      message: boundedText(error.message, 2048),
      retryable: false,
    });
  }
}
