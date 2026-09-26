#!/usr/bin/env node
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const protocolVersion = "1.0";
const maxPromptBytes = 512 * 1024;
const maxCliStdoutBytes = 8 * 1024 * 1024;
const maxCliStderrBytes = 1024 * 1024;
let adapterVersion = "1.0.0";
let currentAssignment = null;
let currentRequest = null;

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
    "--color",
    "never",
    "--cd",
    process.cwd(),
  ];
  if (model) args.push("--model", model);
  args.push("-");
  return args;
}

async function runCli(prompt, model, requestId, assignmentId) {
  const child = spawn("antigravity", cliArgs(model), {
    cwd: process.cwd(),
    env: process.env,
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true,
  });
  let stdoutBytes = 0;
  let stderrBytes = 0;
  let finalMessage = "";
  let turnCompleted = false;
  let cliError = null;

  const stdout = createInterface({ input: child.stdout, crlfDelay: Infinity });
  stdout.on("line", (line) => {
    stdoutBytes += Buffer.byteLength(line, "utf8") + 1;
    if (stdoutBytes > maxCliStdoutBytes) {
      cliError = "Antigravity output exceeded the adapter limit.";
      child.kill();
      return;
    }
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      return;
    }
    if (
      event.type === "item.completed" &&
      event.item?.type === "agent_message"
    ) {
      finalMessage = boundedText(event.item.text, 512 * 1024);
    } else if (
      event.type === "item.completed" &&
      event.item?.type === "command_execution"
    ) {
      // Command output may contain repository data or provider diagnostics.
      // Never forward raw tool output as realtime progress.
      send("progress", {
        requestId,
        assignmentId,
        message:
          "Antigravity is executing a command in the Workstream workspace.",
      });
    } else if (event.type === "turn.completed") {
      turnCompleted = true;
    } else if (event.type === "turn.failed") {
      cliError =
        boundedText(event.error?.message, 2048) ||
        "Antigravity execution failed.";
    } else if (event.type === "error") {
      cliError =
        boundedText(event.message, 2048) || "Antigravity execution failed.";
    }
  });

  child.stderr.on("data", (chunk) => {
    stderrBytes += chunk.length;
    if (stderrBytes > maxCliStderrBytes) {
      cliError = "Antigravity diagnostics exceeded the adapter limit.";
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
        `Antigravity exited with code ${exitCode} before completing the turn.`,
    );
  }
  if (!finalMessage)
    throw new Error("Antigravity completed without a final response.");
  return finalMessage;
}

async function checkLogin() {
  const child = spawn("antigravity", ["auth", "status"], {
    cwd: process.cwd(),
    env: process.env,
    stdio: ["ignore", "ignore", "ignore"],
    windowsHide: true,
  });
  const code = await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", resolve);
  });
  return code === 0;
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
    case "version.request":
      send("version.result", { requestId, adapterVersion, protocolVersion });
      break;
    case "health.request":
      send("health.result", { requestId, healthy: true });
      break;
    case "validate.request": {
      const loggedIn = await checkLogin().catch(() => false);
      send("validate.result", {
        requestId,
        ready: loggedIn,
        issues: loggedIn
          ? []
          : [
              {
                code: "authentication_required",
                message:
                  "Sign in to Antigravity with your Google account on this computer, then validate again.",
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
      currentRequest = requestId;
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
        send("error", {
          requestId,
          assignmentId: frame.assignmentId,
          code: "antigravity_execution_failed",
          message: boundedText(error.message, 2048),
          retryable: true,
        });
      } finally {
        currentAssignment = null;
        currentRequest = null;
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
  try {
    const frame = JSON.parse(line);
    await handle(frame);
  } catch (error) {
    send("error", {
      ...(currentRequest ? { requestId: currentRequest } : {}),
      ...(currentAssignment ? { assignmentId: currentAssignment } : {}),
      code: "invalid_request",
      message: boundedText(error.message, 2048),
      retryable: false,
    });
  }
}
