#!/usr/bin/env node
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const protocolVersion = "2.1";
const maxPromptBytes = 512 * 1024;
const maxCliStdoutBytes = 8 * 1024 * 1024;
const maxCliStderrBytes = 1024 * 1024;
let adapterVersion = "1.0.0";
let currentAssignment = null;
const cliExecutable = process.env.CONCLAVE_CLI_EXECUTABLE || "agy";

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

function cliEnvironment() {
  const env = {};
  for (const name of [
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
  ]) {
    if (typeof process.env[name] === "string") env[name] = process.env[name];
  }
  return env;
}

function cliArgs(model) {
  const args = [
    "--input-format",
    "stream-json",
    "--output-format",
    "stream-json",
    "--sandbox",
    "--print-timeout",
    "15m",
  ];
  if (model) args.push("--model", model);
  return args;
}

function classifyCliFailure(diagnostic) {
  const normalized = (typeof diagnostic === "string" ? diagnostic : "")
    .toLowerCase()
    .replaceAll("_", " ");
  if (/\b(cancelled|canceled|user interrupted)\b/.test(normalized))
    return "cancelled";
  if (/\b(timeout|timed out|deadline exceeded)\b/.test(normalized))
    return "timeout";
  if (/\bunsupported (cli|tool) version\b/.test(normalized))
    return "unsupported_cli_version";
  if (/\b(enoent|executable not found|command not found)\b/.test(normalized))
    return "cli_not_found";
  if (
    /\b(unauthori[sz]ed|authentication required|not authenticated|sign in|login required|credentials? (missing|expired|invalid)|gemini api key.{0,40}(not set|missing)|invalid api key|token expired)\b/s.test(
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
    unsupported_cli_version:
      "The installed local CLI version is not supported.",
    timeout: "The assignment exceeded its time limit.",
    cancelled: "The assignment was cancelled.",
    internal_adapter_error: "The local Worker integration needs attention.",
  };
  return messages[code] || messages.execution_failed;
}

async function runCli(prompt, model, requestId, assignmentId) {
  const child = spawn(cliExecutable, cliArgs(model), {
    cwd: process.cwd(),
    env: cliEnvironment(),
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true,
  });
  let stdoutBytes = 0;
  let stderrBytes = 0;
  let finalMessage = "";
  let completed = false;
  let cliError = null;
  let cliDiagnostics = "";
  let progressSent = false;

  const stdout = createInterface({ input: child.stdout, crlfDelay: Infinity });
  child.stdout.on("data", (chunk) => {
    stdoutBytes += chunk.length;
    if (stdoutBytes > maxCliStdoutBytes) {
      cliError = "Antigravity output exceeded the adapter limit.";
      child.kill();
    }
  });
  stdout.on("line", (line) => {
    if (cliError) return;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      cliError = "Antigravity emitted a malformed JSON event.";
      child.kill();
      return;
    }
    if (event.event === "init") {
      return;
    }
    if (event.event === "step_update") {
      if (!progressSent) {
        progressSent = true;
        send("progress", {
          requestId,
          assignmentId,
          message: "Antigravity is working in the Workstream workspace.",
        });
      }
      return;
    }
    if (event.event === "result") {
      completed = true;
      const status = event.result?.status;
      if (status === "SUCCESS") {
        finalMessage = boundedText(event.result?.response, 512 * 1024);
      } else {
        cliError =
          boundedText(event.result?.error, 2048) ||
          `Antigravity ended with status ${status || "ERROR"}.`;
      }
    }
  });

  child.stderr.on("data", (chunk) => {
    stderrBytes += chunk.length;
    if (Buffer.byteLength(cliDiagnostics, "utf8") < 2048) {
      cliDiagnostics = boundedText(
        cliDiagnostics + chunk.toString("utf8"),
        2048,
      );
    }
    if (stderrBytes > maxCliStderrBytes) {
      cliError = "Antigravity diagnostics exceeded the adapter limit.";
      child.kill();
    }
  });
  child.stdin.end(
    `${JSON.stringify({
      event: "user",
      message: { content: prompt },
    })}\n`,
  );

  const exitCode = await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", resolve);
  });
  if (exitCode !== 0 || cliError || !completed) {
    const diagnostic =
      cliError ||
      cliDiagnostics ||
      `Antigravity exited with code ${exitCode} before completing the turn.`;
    const error = new Error(diagnostic);
    error.code = classifyCliFailure(diagnostic);
    throw error;
  }
  if (!finalMessage) {
    const error = new Error("Antigravity completed without a final response.");
    error.code = "execution_failed";
    throw error;
  }
  return finalMessage;
}

async function toolVersion() {
  const child = spawn(cliExecutable, ["--version"], {
    cwd: process.cwd(),
    env: cliEnvironment(),
    stdio: ["ignore", "pipe", "ignore"],
    windowsHide: true,
  });
  let output = "";
  child.stdout.on("data", (chunk) => {
    if (output.length < 512) output += chunk.toString("utf8");
  });
  const code = await new Promise((resolve) => {
    child.once("error", () => resolve(-1));
    child.once("close", resolve);
  });
  const match =
    code === 0
      ? output.match(/\b(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)\b/)
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
      const detectedVersion = await toolVersion().catch(() => null);
      // Antigravity has no documented non-interactive authentication-status
      // command. Setup/manual tests verify cached auth via headless execution.
      const ready = detectedVersion !== null;
      send("probe.result", {
        requestId,
        ready,
        toolVersion: detectedVersion,
        checkKind: "readiness",
        issues: ready
          ? []
          : [
              {
                code: "cli_not_found",
                message:
                  "Antigravity CLI is unavailable or its version could not be read.",
              },
            ],
      });
      break;
    }
    case "execute.request": {
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
