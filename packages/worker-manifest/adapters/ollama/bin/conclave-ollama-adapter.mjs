#!/usr/bin/env node
import { createInterface } from "node:readline";

const protocolVersion = "1.0";
const modelsLimit = 500;
let adapterVersion = "1.0.0";
let endpoint = "http://localhost:11434";
const send = (type, requestId, fields = {}) =>
  process.stdout.write(
    `${JSON.stringify({ type, protocolVersion, requestId, ...fields })}\n`,
  );

function apiUrl(path) {
  const base = new URL(endpoint);
  base.pathname = `${base.pathname.replace(/\/+$/, "")}${path}`;
  return base;
}

async function get(path) {
  const response = await fetch(apiUrl(path), {
    signal: AbortSignal.timeout(5000),
  });
  if (!response.ok) throw new Error(`Ollama returned HTTP ${response.status}.`);
  return response.json();
}

async function discover() {
  await get("/api/version");
  const value = await get("/api/tags");
  return Array.isArray(value.models)
    ? value.models
        .map((model) => model.name)
        .filter((name) => typeof name === "string")
        .slice(0, modelsLimit)
    : [];
}

async function handle(frame) {
  switch (frame.type) {
    case "initialize.request":
      if (frame.workerTypeId !== "ollama")
        throw new Error("Unsupported Worker Type.");
      adapterVersion = frame.adapterVersion;
      send("initialize.result", frame.requestId, {
        adapterVersion,
        capabilities: ["text_generation"],
      });
      break;
    case "version.request":
      send("version.result", frame.requestId, { adapterVersion });
      break;
    case "health.request":
      send("health.result", frame.requestId, { healthy: true });
      break;
    case "validate.request": {
      const configured = frame.config?.endpointUrl;
      try {
        const candidate = new URL(
          typeof configured === "string" ? configured : endpoint,
        );
        const local = ["localhost", "127.0.0.1", "[::1]"].includes(
          candidate.hostname,
        );
        if (
          (!local && candidate.protocol !== "https:") ||
          (local && !["http:", "https:"].includes(candidate.protocol)) ||
          candidate.username ||
          candidate.password ||
          candidate.search ||
          candidate.hash
        )
          throw new Error(
            "Use a local Ollama endpoint or an HTTPS endpoint without credentials.",
          );
        endpoint = candidate.toString().replace(/\/$/, "");
        const models = await discover();
        send("validate.result", frame.requestId, {
          ready: models.length > 0,
          issues: models.length
            ? []
            : [
                {
                  code: "models_missing",
                  message:
                    "Ollama is available, but no models are installed. Pull a model, then validate again.",
                },
              ],
          models,
        });
      } catch (error) {
        send("validate.result", frame.requestId, {
          ready: false,
          issues: [
            {
              code: "ollama_unavailable",
              message: error.message || "Ollama could not be reached.",
            },
          ],
          models: [],
        });
      }
      break;
    }
    case "execute.request": {
      const model = typeof frame.model === "string" ? frame.model.trim() : "";
      if (!model) {
        send("error", frame.requestId, {
          assignmentId: frame.assignmentId,
          code: "model_required",
          message: "Select an installed Ollama model.",
          retryable: false,
        });
        break;
      }
      send("progress", frame.requestId, {
        assignmentId: frame.assignmentId,
        message: `Ollama is generating a response with ${model}.`,
      });
      try {
        const installed = await discover();
        if (!installed.includes(model)) {
          send("error", frame.requestId, {
            assignmentId: frame.assignmentId,
            code: "model_not_found",
            message: "The selected model is not installed in Ollama.",
            retryable: false,
          });
          break;
        }
        const response = await fetch(apiUrl("/api/chat"), {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            model,
            messages: [{ role: "user", content: frame.prompt }],
            stream: false,
          }),
          signal: AbortSignal.timeout(120000),
        });
        if (!response.ok)
          throw new Error(`Ollama returned HTTP ${response.status}.`);
        const value = await response.json();
        const output = value.message?.content;
        if (typeof output !== "string" || Buffer.byteLength(output) > 500000)
          throw new Error("Ollama returned an invalid or oversized response.");
        send("result", frame.requestId, {
          assignmentId: frame.assignmentId,
          output,
          artifacts: [],
        });
      } catch (error) {
        send("error", frame.requestId, {
          assignmentId: frame.assignmentId,
          code: "ollama_request_failed",
          message: error.message || "Ollama request failed.",
          retryable: true,
        });
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
    send("error", "invalid", {
      code: "invalid_request",
      message: error.message || "Invalid request.",
      retryable: false,
    });
  }
}
