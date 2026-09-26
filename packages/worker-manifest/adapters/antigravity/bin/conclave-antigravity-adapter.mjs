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

async function runCli(prompt, model, requestId, assignmentId) {
  const child = spawn("agy", cliArgs(model), {
    cwd: process.cwd(),
    env: process.env,
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true,
  });
  let stdoutBytes = 0;
  let stderrBytes = 0;
  let finalMessage = "";
  let completed = false;
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
    if (event.event === "step_update") {
      send("progress", {
        requestId,
        assignmentId,
        message: "Antigravity is working in the Workstream workspace.",
      });
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
  // Antigravity has no documented non-interactive "auth status" command.
  // /usage is handled by the CLI itself and validates that a local account
  // session is available without spending a model turn.
  const child = spawn("agy", ["-p", "/usage"], {
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
