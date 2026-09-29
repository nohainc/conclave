#!/usr/bin/env node
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const protocolVersion = "2.1";
const maxPromptBytes = 512 * 1024;
const maxCliStdoutBytes = 8 * 1024 * 1024;
const maxCliStderrBytes = 1024 * 1024;
let adapterVersion = "1.0.0";
let currentAssignment = null;
const cliExecutable = process.env.CONCLAVE_CLI_EXECUTABLE || "codex";

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

function cliArgs(model) {
  const args = [
    "--ask-for-approval",
    "never",
    "--sandbox",
    "workspace-write",
    "exec",
    "--json",
    "--ephemeral",
    "--color",
    "never",
    "--skip-git-repo-check",
    "--cd",
    process.cwd(),
  ];
  if (model) args.push("--model", model);
  args.push("-");
  return args;
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
  let turnCompleted = false;
  let cliError = null;
  let stderrDiagnostic = "";

  const stdout = createInterface({ input: child.stdout, crlfDelay: Infinity });
  child.stdout.on("data", (chunk) => {
    stdoutBytes += chunk.length;
    if (stdoutBytes > maxCliStdoutBytes) {
      cliError = "Codex output exceeded the adapter limit.";
      child.kill();
    }
  });
  stdout.on("line", (line) => {
    if (cliError) return;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      cliError = "Codex emitted a malformed JSON event.";
      child.kill();
      return;
    }
    if (
      event.type === "item.completed" &&
      event.item?.type === "agent_message"
    ) {
      finalMessage = boundedText(event.item.text, 512 * 1024);
    } else if (event.type === "turn.started") {
      send("progress", {
        requestId,
        assignmentId,
        message: "Codex is working on the Workstream assignment.",
      });
    } else if (
      ["item.started", "item.updated", "item.completed"].includes(event.type) &&
      ["command_execution", "mcp_tool_call", "web_search_call"].includes(
        event.item?.type,
      )
    ) {
      // Command output may contain repository data or provider diagnostics.
      // Never forward raw tool output as realtime progress.
      send("progress", {
        requestId,
        assignmentId,
        message: "Codex is executing a command in the Workstream workspace.",
      });
    } else if (event.type === "turn.completed") {
      turnCompleted = true;
    } else if (event.type === "turn.failed") {
      cliError =
        boundedText(event.error?.message, 2048) || "Codex execution failed.";
    } else if (event.type === "error") {
      cliError =
        boundedText(event.message || event.error?.message, 2048) ||
        "Codex execution failed.";
    }
  });

  child.stderr.on("data", (chunk) => {
    stderrBytes += chunk.length;
    if (Buffer.byteLength(stderrDiagnostic, "utf8") < 2048) {
      stderrDiagnostic = boundedText(
        stderrDiagnostic + chunk.toString("utf8"),
        2048,
      );
    }
    if (stderrBytes > maxCliStderrBytes) {
      cliError = "Codex diagnostics exceeded the adapter limit.";
      child.kill();
    }
  });
  child.stdin.end(prompt);

  const exitCode = await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", resolve);
  });
  if (exitCode !== 0 || cliError || !turnCompleted) {
    throw new Error(
      cliError ||
        stderrDiagnostic ||
        `Codex exited with code ${exitCode} before completing the turn.`,
    );
  }
  if (!finalMessage)
    throw new Error("Codex completed without a final response.");
  return finalMessage;
}

async function checkLogin() {
  const child = spawn(cliExecutable, ["login", "status"], {
    cwd: process.cwd(),
    env: cliEnvironment(),
    stdio: ["ignore", "ignore", "ignore"],
    windowsHide: true,
  });
  const code = await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", resolve);
  });
  return code === 0;
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
  if (code !== 0) return null;
  const match = output.match(/\b(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)\b/);
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
      const detectedVersion = await toolVersion().catch(() => null);
      const loggedIn = await checkLogin().catch(() => false);
      const ready = detectedVersion !== null && loggedIn;
      send("probe.result", {
        requestId,
        ready,
        toolVersion: detectedVersion,
        checkKind: "readiness",
        issues: ready
          ? []
          : [
              {
                code: detectedVersion
                  ? "authentication_required"
                  : "cli_not_found",
                message: detectedVersion
                  ? "Sign in to Codex on this computer, then check again."
                  : "Codex CLI is unavailable or its version could not be read.",
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
