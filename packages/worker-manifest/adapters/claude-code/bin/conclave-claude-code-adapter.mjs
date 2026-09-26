#!/usr/bin/env node
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const protocolVersion = "1.0";
let adapterVersion = "1.0.0";
let child = null;
let activeRequest = null;
let activeAssignment = null;
const send = (type, requestId, fields = {}) =>
  process.stdout.write(
    `${JSON.stringify({ type, protocolVersion, requestId, ...fields })}\n`,
  );
const bounded = (text, size = 500000) =>
  Buffer.from(String(text ?? ""))
    .subarray(0, size)
    .toString("utf8");

function run(args, prompt, requestId, assignmentId) {
  return new Promise((resolve, reject) => {
    child = spawn("claude", args, {
      cwd: process.cwd(),
      env: process.env,
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    let stdout = "";
    let stderrBytes = 0;
    child.stdout.on("data", (chunk) => {
      if (Buffer.byteLength(stdout) + chunk.length > 8 * 1024 * 1024) {
        child.kill();
        reject(new Error("Claude Code output exceeded the adapter limit."));
        return;
      }
      stdout += chunk.toString("utf8");
    });
    child.stderr.on("data", (chunk) => {
      stderrBytes += chunk.length;
      if (stderrBytes > 1024 * 1024) child.kill();
    });
    child.once("error", reject);
    child.once("close", (code) => {
      child = null;
      if (code !== 0) {
        reject(
          new Error(
            code === null
              ? "Claude Code execution was cancelled."
              : `Claude Code exited with code ${code}. Check local authentication and permissions.`,
          ),
        );
        return;
      }
      try {
        const frames = stdout
          .split(/\r?\n/)
          .filter(Boolean)
          .map((line) => JSON.parse(line));
        let output = "";
        for (const event of frames) {
          if (
            event.type === "assistant" ||
            event.type === "content_block_delta"
          )
            send("progress", requestId, {
              assignmentId,
              message: "Claude Code is working in the Workstream workspace.",
            });
          if (event.type === "result") {
            if (event.is_error)
              throw new Error("Claude Code reported an execution error.");
            output = typeof event.result === "string" ? event.result : "";
          }
        }
        if (!output) output = stdout.trim();
        if (!output)
          throw new Error("Claude Code completed without a response.");
        resolve(bounded(output));
      } catch (error) {
        reject(error);
      }
    });
    child.stdin.end(prompt);
  });
}

async function authenticated() {
  return new Promise((resolve) => {
    const check = spawn("claude", ["auth", "status"], {
      cwd: process.cwd(),
      env: process.env,
      stdio: "ignore",
      windowsHide: true,
    });
    const timer = setTimeout(() => {
      check.kill();
      resolve(false);
    }, 8000);
    check.once("error", () => {
      clearTimeout(timer);
      resolve(false);
    });
    check.once("close", (code) => {
      clearTimeout(timer);
      resolve(code === 0);
    });
  });
}

async function handle(frame) {
  switch (frame.type) {
    case "initialize.request":
      if (frame.workerTypeId !== "claude-code")
        throw new Error("Unsupported Worker Type.");
      adapterVersion = frame.adapterVersion;
      send("initialize.result", frame.requestId, {
        adapterVersion,
        capabilities: ["code", "repository", "shell"],
      });
      break;
    case "version.request":
      send("version.result", frame.requestId, { adapterVersion });
      break;
    case "health.request":
      send("health.result", frame.requestId, { healthy: true });
      break;
    case "validate.request": {
      const ready = await authenticated();
      send("validate.result", frame.requestId, {
        ready,
        issues: ready
          ? []
          : [
              {
                code: "authentication_required",
                message:
                  "Sign in with `claude auth login`, then validate again.",
              },
            ],
      });
      break;
    }
    case "execute.request": {
      if (Buffer.byteLength(frame.prompt ?? "") > 512 * 1024)
        throw new Error("Assignment prompt exceeded the adapter limit.");
      const args = [
        "-p",
        "--output-format",
        "stream-json",
        "--verbose",
        "--dangerously-skip-permissions",
      ];
      if (typeof frame.model === "string" && frame.model.trim())
        args.push("--model", frame.model.trim());
      activeRequest = frame.requestId;
      activeAssignment = frame.assignmentId;
      try {
        const output = await run(
          args,
          frame.prompt,
          frame.requestId,
          frame.assignmentId,
        );
        send("result", frame.requestId, {
          assignmentId: frame.assignmentId,
          output,
          artifacts: [],
        });
      } catch (error) {
        const message = bounded(
          error?.message || "Claude Code execution failed.",
          2048,
        );
        send("error", frame.requestId, {
          assignmentId: frame.assignmentId,
          code: /auth|login|credential/i.test(message)
            ? "authentication_expired"
            : "claude_execution_failed",
          message,
          retryable: /auth|login|credential/i.test(message),
        });
      } finally {
        child = null;
        activeRequest = null;
        activeAssignment = null;
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
    await handle(JSON.parse(line));
  } catch (error) {
    send("error", activeRequest ?? "invalid", {
      ...(activeAssignment ? { assignmentId: activeAssignment } : {}),
      code: "invalid_request",
      message: bounded(error.message, 2048),
      retryable: false,
    });
  }
}
