#!/usr/bin/env node
import { createInterface } from "node:readline";
import { pathToFileURL } from "node:url";
import { providers } from "./providers/index.mjs";

export const protocolVersion = "1.0";
export const maxPromptBytes = 512 * 1024;
const maxResponseBytes = 2 * 1024 * 1024;
const maxResultBytes = 500_000;
let workerTypeId = null;
let adapterVersion = "1.0.0";
let config = {};

export function endpointFor(configured, defaultBase, suffix) {
  const base =
    configured == null || configured === "" ? defaultBase : configured;
  let url;
  try {
    url = new URL(base);
  } catch {
    throw new Error("Endpoint must be a valid HTTPS URL.");
  }
  const localHttp = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if (
    (url.protocol !== "https:" && !(localHttp && url.protocol === "http:")) ||
    url.username ||
    url.password ||
    url.search ||
    url.hash
  ) {
    throw new Error(
      "Endpoint must use HTTPS and cannot contain credentials or query parameters.",
    );
  }
  url.pathname = `${url.pathname.replace(/\/+$/, "")}/${suffix.replace(/^\/+/, "")}`;
  return url;
}

export async function requestJson(
  url,
  method,
  headers,
  payload,
  timeoutMs = 120_000,
) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, {
      method,
      headers: {
        ...(payload === undefined
          ? {}
          : { "content-type": "application/json" }),
        ...headers,
      },
      ...(payload === undefined ? {} : { body: JSON.stringify(payload) }),
      signal: controller.signal,
    });
    const reader = response.body?.getReader();
    if (!reader) throw new Error("Provider returned an empty response.");
    const chunks = [];
    let total = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxResponseBytes) {
        controller.abort();
        throw new Error("Provider response exceeded the adapter limit.");
      }
      chunks.push(value);
    }
    const text = Buffer.concat(chunks).toString("utf8");
    if (!response.ok) {
      const error = new Error(
        response.status === 401 || response.status === 403
          ? "Provider authentication failed; check the API key stored in Conclave Workspace."
          : `Provider request failed with HTTP ${response.status}.`,
      );
      error.retryable = response.status === 429 || response.status >= 500;
      throw error;
    }
    try {
      return JSON.parse(text);
    } catch {
      throw new Error("Provider returned an invalid response.");
    }
  } finally {
    clearTimeout(timeout);
  }
}

export function postJson(url, headers, payload, timeoutMs) {
  return requestJson(url, "POST", headers, payload, timeoutMs);
}

export function getJson(url, headers, timeoutMs) {
  return requestJson(url, "GET", headers, undefined, timeoutMs);
}

function send(type, requestId, fields = {}) {
  process.stdout.write(
    `${JSON.stringify({ type, protocolVersion, requestId, ...fields })}\n`,
  );
}

function endpointConfigIsValid(value) {
  try {
    endpointFor(value.endpointUrl, "https://invalid.example", "");
    return true;
  } catch {
    return false;
  }
}

async function handle(frame) {
  const provider = workerTypeId == null ? null : providers[workerTypeId];
  switch (frame.type) {
    case "initialize.request":
      if (!providers[frame.workerTypeId])
        throw new Error("Unsupported API Worker Type.");
      workerTypeId = frame.workerTypeId;
      adapterVersion = frame.adapterVersion;
      send("initialize.result", frame.requestId, {
        adapterVersion,
        capabilities: ["text_generation"],
      });
      return;
    case "version.request":
      send("version.result", frame.requestId, {
        adapterVersion,
        protocolVersion,
      });
      return;
    case "health.request":
      send("health.result", frame.requestId, { healthy: true });
      return;
    case "validate.request":
      config = Object.fromEntries(
        Object.entries(frame.config ?? {}).filter(
          ([key, value]) =>
            ["endpointUrl", "organizationId", "projectId"].includes(key) &&
            typeof value === "string" &&
            value.length <= 2048,
        ),
      );
      if (!process.env.CONCLAVE_PROVIDER_API_KEY) {
        send("validate.result", frame.requestId, {
          ready: false,
          issues: [
            {
              code: "credential_missing",
              message: "Add an API key in Conclave Workspace.",
            },
          ],
        });
      } else if (!endpointConfigIsValid(config)) {
        send("validate.result", frame.requestId, {
          ready: false,
          issues: [
            {
              code: "endpoint_invalid",
              message: "The configured API endpoint is invalid.",
            },
          ],
        });
      } else {
        try {
          const models = await provider.validateCredential({
            apiKey: process.env.CONCLAVE_PROVIDER_API_KEY,
            config,
          });
          send("validate.result", frame.requestId, {
            ready: true,
            issues: [],
            models: Array.isArray(models) ? models.slice(0, 500) : [],
          });
        } catch (error) {
          send("validate.result", frame.requestId, {
            ready: false,
            issues: [
              {
                code: "credential_invalid",
                message: error.message || "Provider API key validation failed.",
              },
            ],
          });
        }
      }
      return;
    case "execute.request": {
      if (!provider) throw new Error("API adapter was not initialized.");
      if (Buffer.byteLength(frame.prompt ?? "", "utf8") > maxPromptBytes) {
        throw new Error("Assignment prompt exceeded the adapter limit.");
      }
      if (typeof frame.model !== "string" || !frame.model.trim()) {
        send("error", frame.requestId, {
          assignmentId: frame.assignmentId,
          code: "model_required",
          message:
            "Set a default model for this API Worker in Conclave Workspace.",
          retryable: false,
        });
        return;
      }
      send("progress", frame.requestId, {
        assignmentId: frame.assignmentId,
        message: `${provider.displayName} is generating a response.`,
      });
      try {
        const output = await provider.generate({
          apiKey: process.env.CONCLAVE_PROVIDER_API_KEY,
          model: frame.model,
          prompt: frame.prompt,
          config,
        });
        if (Buffer.byteLength(output, "utf8") > maxResultBytes) {
          send("error", frame.requestId, {
            assignmentId: frame.assignmentId,
            code: "result_too_large",
            message: "Provider response exceeded the adapter result limit.",
            retryable: false,
          });
          return;
        }
        send("result", frame.requestId, {
          assignmentId: frame.assignmentId,
          output,
          artifacts: [],
        });
      } catch (error) {
        send("error", frame.requestId, {
          assignmentId: frame.assignmentId,
          code: "provider_request_failed",
          message: error.message || "Provider request failed.",
          retryable: error.retryable === true,
        });
      }
      return;
    }
    default:
      throw new Error("Unsupported API adapter request.");
  }
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
  for await (const line of input) {
    if (!line.trim()) continue;
    let frame;
    try {
      frame = JSON.parse(line);
      await handle(frame);
    } catch (error) {
      send("error", frame?.requestId ?? "invalid", {
        ...(frame?.assignmentId ? { assignmentId: frame.assignmentId } : {}),
        code: "invalid_request",
        message: error.message || "Invalid adapter request.",
        retryable: false,
      });
    }
  }
}
