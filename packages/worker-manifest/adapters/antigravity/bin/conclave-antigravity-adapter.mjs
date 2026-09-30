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
const cliExecutable = "agy";
const homeDirectory = process.env.HOME || process.env.USERPROFILE;
const environmentPolicy = readPackageEnvironmentPolicy(import.meta.url);
const cliEnvironment = buildCliEnvironment({
  passthrough: environmentPolicy.providerCliPassthrough,
});
const cliTool = new CliToolRunner({
  executable: cliExecutable,
  env: cliEnvironment,
  packageId: "antigravity",
  knownDirectories: [
    ...(homeDirectory
      ? [
          join(homeDirectory, ".local", "bin"),
          join(homeDirectory, "AppData", "Local", "agy", "bin"),
        ]
      : []),
    ...(process.platform === "win32"
      ? [
          join(
            process.env.ProgramFiles || "C:\\Program Files",
            "Google",
            "antigravity-cli",
          ),
        ]
      : []),
  ],
});
const cliSessions = new CliSessionStore({
  packageId: "antigravity",
  env: process.env,
});

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

function cliArgs(model, deadlineAt, providerSessionId = null) {
  const timeoutSeconds = Math.max(
    1,
    Math.floor((deadlineAt - Date.now() - CLI_CLEANUP_GRACE_MS) / 1000),
  );
  const args = [
    "--input-format",
    "stream-json",
    "--output-format",
    "stream-json",
    "--sandbox",
    "--print-timeout",
    `${timeoutSeconds}s`,
  ];
  if (providerSessionId) args.push("--conversation", providerSessionId);
  if (model) args.push("--model", model);
  return args;
}

const CLI_CLEANUP_GRACE_MS = 1500;

function classifyCliFailure(diagnostic) {
  const normalized = (typeof diagnostic === "string" ? diagnostic : "")
    .toLowerCase()
    .replaceAll("_", " ");
  if (/\b(cancelled|canceled|interrupted|user interrupted)\b/.test(normalized))
    return "cancelled";
  if (/\b(timeout|timed out|deadline exceeded)\b/.test(normalized))
    return "timeout";
  if (/\bunsupported (cli|tool) version\b/.test(normalized))
    return "unsupported_cli_version";
  if (/\b(enoent|executable not found|command not found)\b/.test(normalized))
    return "cli_not_found";
  if (
    /\b(unauthori[sz]ed|authentication required|not authenticated|sign in|login required|credentials? (missing|expired|invalid)|gemini api key.{0,40}(not set|missing)|api key.{0,40}(invalid|not valid|revoked|expired)|(?:invalid|revoked|expired).{0,40}api key|token expired)\b/s.test(
      normalized,
    )
  )
    return "authentication_required";
  if (
    /\b(model (not found|unsupported|not supported)|unsupported model|unknown model|invalid model)\b/.test(
      normalized,
    )
  )
    return "model_not_supported";
  if (
    /\b(quota|resource exhausted|usage limit|rate limit|too many requests|\b429\b)\b/.test(
      normalized,
    )
  )
    return "quota_exhausted";
  if (
    /\b(server overloaded|service unavailable|provider unavailable|unavailable|connection refused|network error|\b5\d\d\b)\b/.test(
      normalized,
    )
  )
    return "provider_unavailable";
  if (
    /\bpermission.{0,60}(configuration|settings)\b|\b(configuration|settings).{0,60}\bpermission\b|\bpermission setup.{0,40}\brequired\b/s.test(
      normalized,
    )
  )
    return "permission_configuration_required";
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
    model_not_supported: "The selected model is not supported by this Worker.",
    quota_exhausted: "The provider's usage limit has been reached.",
    provider_unavailable: "The provider is temporarily unavailable.",
    permission_configuration_required:
      "A local permission setting is required before execution.",
    permission_denied:
      "A local permission required for this assignment was denied.",
    execution_failed: "The assignment could not be completed.",
    execution_test_failed: "The live probe did not complete successfully.",
    unsupported_cli_version:
      "The installed local CLI version is not supported.",
    timeout: "The assignment exceeded its time limit.",
    cancelled: "The assignment was cancelled.",
    internal_adapter_error: "The local Worker integration needs attention.",
  };
  return messages[code] || messages.execution_failed;
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
  const priorSessionId =
    sessionPolicy === "durable_session"
      ? await cliSessions.get(sessionKey)
      : null;
  const cliDeadlineAt = deadlineAt - CLI_CLEANUP_GRACE_MS;
  const controller = new AbortController();
  activeCliController = controller;
  let finalMessage = "";
  let completed = false;
  let cliError = null;
  let progressSent = false;
  let observedSessionId = null;
  const result = await cliTool
    .runStream(cliArgs(model, deadlineAt, priorSessionId), {
      stdin: `${JSON.stringify({ event: "user", message: { content: prompt } })}\n`,
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
          throw new Error("Antigravity emitted a malformed JSON event.");
        }
        if (event.event === "init") {
          observedSessionId =
            typeof event.conversation_id === "string"
              ? event.conversation_id
              : null;
          if (priorSessionId && observedSessionId !== priorSessionId) {
            cliError =
              "Antigravity started a different conversation instead of resuming.";
            throw Object.assign(new Error(cliError), {
              code: "execution_failed",
            });
          }
          return;
        }
        if (event.event === "step_update") {
          if (!progressSent) {
            progressSent = true;
            if (requestId)
              send("progress", {
                requestId,
                assignmentId,
                message: "Gemini is working in the Workstream workspace.",
              });
          }
          return;
        }
        if (event.event === "result") {
          completed = true;
          const resultConversationId = event.result?.conversation_id;
          if (typeof resultConversationId === "string") {
            if (
              observedSessionId &&
              observedSessionId !== resultConversationId
            ) {
              const error = new Error(
                "Antigravity returned inconsistent conversation IDs.",
              );
              error.code = "execution_failed";
              throw error;
            }
            observedSessionId = resultConversationId;
          }
          const status = event.result?.status;
          if (status === "SUCCESS") {
            finalMessage = boundedText(event.result?.response, 512 * 1024);
          } else {
            cliError =
              boundedText(event.result?.error, 2048) ||
              `Antigravity ended with status ${status || "ERROR"}.`;
            throw Object.assign(new Error(cliError), {
              code: classifyCliFailure(cliError),
            });
          }
        }
      },
    })
    .finally(() => {
      if (activeCliController === controller) activeCliController = null;
    });
  if (result.exitCode !== 0 || cliError || !completed) {
    const diagnostic =
      cliError ||
      result.stderr ||
      `Antigravity exited with code ${result.exitCode} before completing the turn.`;
    const error = new Error(diagnostic);
    error.code = classifyCliFailure(diagnostic);
    throw error;
  }
  if (!finalMessage) {
    const error = new Error("Antigravity completed without a final response.");
    error.code = "execution_failed";
    throw error;
  }
  if (sessionPolicy === "durable_session") {
    if (
      !observedSessionId ||
      (priorSessionId && observedSessionId !== priorSessionId)
    ) {
      const error = new Error(
        "Antigravity did not resume or establish the requested local session.",
      );
      error.code = "execution_failed";
      throw error;
    }
    await cliSessions.set(sessionKey, observedSessionId);
  }
  return finalMessage;
}

async function toolVersion() {
  const { exitCode, stdout } = await cliTool.runCommand(["--version"], {
    timeoutMs: 10_000,
    stdoutLimit: 512,
    stderrLimit: 4096,
    requireSuccess: false,
  });
  const match =
    exitCode === 0
      ? stdout.match(/\b(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)\b/)
      : null;
  return match?.[1] ?? null;
}

async function handle(frame) {
  const requestId = frame.requestId;
  switch (frame.type) {
    case "initialize.request":
      if (frame.workerTypeId !== "antigravity")
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
      // The CLI has no cheap supported authentication check. Report the
      // explicit setup action until a live request confirms this configuration.
      const authenticationCheck = {
        id: "authentication",
        status: "skipped",
        issueCode: "setup_required",
        diagnostic: "Authentication is checked by a live probe.",
      };
      checks.push(authenticationCheck);
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
          if (result.trim() === "OK") {
            authenticationCheck.status = "passed";
            delete authenticationCheck.issueCode;
            delete authenticationCheck.diagnostic;
          }
        } catch (error) {
          const issueCode =
            error?.code === "ENOENT"
              ? "cli_not_found"
              : [
                    "cli_not_found",
                    "authentication_required",
                    "unsupported_cli_version",
                    "model_not_supported",
                    "quota_exhausted",
                    "provider_unavailable",
                    "permission_denied",
                    "timeout",
                    "cancelled",
                  ].includes(error?.code)
                ? error.code
                : "execution_test_failed";
          checks.push({
            id: "execution",
            status: "failed",
            issueCode,
            diagnostic: safeFailure(issueCode),
          });
          if (issueCode === "authentication_required") {
            authenticationCheck.status = "failed";
            authenticationCheck.issueCode = issueCode;
            authenticationCheck.diagnostic = safeFailure(issueCode);
          }
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
            : [
                  "cli_not_found",
                  "authentication_required",
                  "unsupported_cli_version",
                  "model_not_supported",
                  "quota_exhausted",
                  "provider_unavailable",
                  "permission_denied",
                  "timeout",
                  "cancelled",
                ].includes(error?.code)
              ? error.code
              : error?.code === "permission_configuration_required"
                ? "permission_denied"
                : "execution_failed";
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
