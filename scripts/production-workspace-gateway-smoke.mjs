import { execFileSync } from "node:child_process";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { once } from "node:events";
import { connect as connectTls } from "node:tls";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const wrangler = join(repositoryRoot, "node_modules/.bin/wrangler");
const config = join(repositoryRoot, "infra/cloudflare/app.wrangler.jsonc");
const hostname = "app.conclaveax.com";
const runId = process.env.GITHUB_RUN_ID
  ? `${process.env.GITHUB_RUN_ID}-${process.env.GITHUB_RUN_ATTEMPT ?? "1"}`
  : randomUUID();
const ownerId = `gateway-smoke-user-${runId}`;
const workspaceId = `gateway-smoke-workspace-${runId}`;
const runtimeId = `runtime-gateway-smoke-${runId}`;
const runtimeToken = randomBytes(32).toString("base64url");
const tokenHash = createHash("sha256").update(runtimeToken).digest("hex");

function sqlString(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

function executeD1(sql) {
  const output = execFileSync(
    wrangler,
    [
      "d1",
      "execute",
      "conclave-v8-production",
      "--remote",
      "--yes",
      "--config",
      config,
      "--command",
      sql,
      "--json",
    ],
    {
      cwd: repositoryRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  return JSON.parse(output);
}

function rowsFromD1(result) {
  if (Array.isArray(result)) {
    return result.flatMap((statement) => statement?.results ?? []);
  }
  return result?.results ?? [];
}

class SocketReader {
  constructor(socket) {
    this.socket = socket;
    this.buffer = Buffer.alloc(0);
    this.pending = [];
    socket.on("data", (chunk) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      for (const resolve of this.pending.splice(0)) resolve();
    });
    socket.on("close", () => {
      for (const resolve of this.pending.splice(0)) resolve();
    });
  }

  async readUntil(marker, timeoutMs) {
    const delimiter = Buffer.from(marker);
    const deadline = Date.now() + timeoutMs;
    while (true) {
      const index = this.buffer.indexOf(delimiter);
      if (index >= 0) {
        const value = this.buffer.subarray(0, index + delimiter.length);
        this.buffer = this.buffer.subarray(index + delimiter.length);
        return value;
      }
      await this.waitForData(deadline);
    }
  }

  async readBytes(length, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    while (this.buffer.length < length) await this.waitForData(deadline);
    const value = this.buffer.subarray(0, length);
    this.buffer = this.buffer.subarray(length);
    return value;
  }

  async waitForData(deadline) {
    if (this.socket.destroyed) throw new Error("Gateway closed the socket");
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error("Timed out waiting for Gateway data");
    await new Promise((resolve, reject) => {
      const onData = () => {
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(() => {
        this.pending = this.pending.filter((pending) => pending !== onData);
        reject(new Error("Timed out waiting for Gateway data"));
      }, remaining);
      this.pending.push(onData);
    });
  }
}

function maskedFrame(value, opcode = 0x1) {
  const payload = Buffer.from(value);
  const extendedLength = payload.length >= 126;
  const header = Buffer.alloc(extendedLength ? 4 : 2);
  header[0] = 0x80 | opcode;
  if (extendedLength) {
    header[1] = 0x80 | 126;
    header.writeUInt16BE(payload.length, 2);
  } else {
    header[1] = 0x80 | payload.length;
  }
  const mask = randomBytes(4);
  const masked = Buffer.from(payload);
  for (let index = 0; index < masked.length; index += 1) {
    masked[index] ^= mask[index % 4];
  }
  return Buffer.concat([header, mask, masked]);
}

async function readServerFrame(reader, timeoutMs) {
  const base = await reader.readBytes(2, timeoutMs);
  const opcode = base[0] & 0x0f;
  let length = base[1] & 0x7f;
  if (length === 126) {
    length = (await reader.readBytes(2, timeoutMs)).readUInt16BE(0);
  } else if (length === 127) {
    const extended = await reader.readBytes(8, timeoutMs);
    const wideLength = extended.readBigUInt64BE(0);
    if (wideLength > 1024n * 1024n) {
      throw new Error("Gateway sent an unexpectedly large WebSocket frame");
    }
    length = Number(wideLength);
  }
  const payload = await reader.readBytes(length, timeoutMs);
  return { opcode, payload };
}

async function waitForProtocolMessage(socket, reader, expectedType) {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    const remaining = deadline - Date.now();
    const frame = await readServerFrame(reader, remaining);
    if (frame.opcode === 0x8)
      throw new Error(`Gateway closed before ${expectedType}`);
    if (frame.opcode === 0x9) {
      socket.write(maskedFrame(frame.payload, 0xa));
      continue;
    }
    if (frame.opcode !== 0x1) continue;
    const message = JSON.parse(frame.payload.toString("utf8"));
    if (message.type === expectedType) return message;
    if (message.type === "error") {
      throw new Error(`Gateway rejected the ${expectedType} exchange`);
    }
  }
  throw new Error(`Timed out waiting for ${expectedType}`);
}

async function connectAndHello() {
  const socket = connectTls({
    host: hostname,
    port: 443,
    servername: hostname,
    ALPNProtocols: ["http/1.1"],
  });
  const reader = new SocketReader(socket);
  try {
    await once(socket, "secureConnect");
    const webSocketKey = randomBytes(16).toString("base64");
    socket.write(
      [
        `GET /api/workspace-gateway/connect?workspaceRuntimeId=${encodeURIComponent(runtimeId)} HTTP/1.1`,
        `Host: ${hostname}`,
        "Upgrade: websocket",
        "Connection: Upgrade",
        `Sec-WebSocket-Key: ${webSocketKey}`,
        "Sec-WebSocket-Version: 13",
        `Authorization: Bearer ${runtimeToken}`,
        `Origin: https://${hostname}`,
        "",
        "",
      ].join("\r\n"),
    );
    const responseHeaders = (
      await reader.readUntil("\r\n\r\n", 15_000)
    ).toString("latin1");
    const statusLine = responseHeaders.split("\r\n", 1)[0];
    if (!/^HTTP\/1\.1 101(?: |$)/.test(statusLine)) {
      throw new Error(`Production Gateway handshake returned ${statusLine}`);
    }
    const expectedAccept = createHash("sha1")
      .update(`${webSocketKey}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
      .digest("base64");
    const acceptHeader = responseHeaders
      .match(/^Sec-WebSocket-Accept:\s*(.+)$/im)?.[1]
      ?.trim();
    if (acceptHeader !== expectedAccept) {
      throw new Error(
        "Production Gateway returned an invalid WebSocket accept key",
      );
    }

    const hello = {
      protocol: "conclave.workspace-runtime-protocol",
      protocolVersion: "5.1",
      messageId: `gateway-smoke-hello-${runId}`,
      timestamp: new Date().toISOString(),
      type: "workspace.hello",
      executionWorkspaceId: workspaceId,
      workspaceRuntimeId: runtimeId,
      payload: {
        platform: "linux",
        architecture: "x64",
        hostname: "github-actions-production-smoke",
        appVersion: "0.0.0-smoke",
        runtimeCapabilities: ["gateway-smoke"],
      },
    };
    socket.write(maskedFrame(JSON.stringify(hello)));
    const acknowledgement = await waitForProtocolMessage(
      socket,
      reader,
      "workspace.hello.ack",
    );
    if (
      acknowledgement.executionWorkspaceId !== workspaceId ||
      acknowledgement.workspaceRuntimeId !== runtimeId
    ) {
      throw new Error(
        "Production Gateway hello acknowledgement identity mismatch",
      );
    }
    const syncRequestId = `gateway-smoke-sync-${runId}`;
    socket.write(
      maskedFrame(
        JSON.stringify({
          protocol: "conclave.workspace-runtime-protocol",
          protocolVersion: "5.1",
          messageId: syncRequestId,
          timestamp: new Date().toISOString(),
          type: "workspace.sync.request",
          executionWorkspaceId: workspaceId,
          workspaceRuntimeId: runtimeId,
          payload: {},
        }),
      ),
    );
    const syncResult = await waitForProtocolMessage(
      socket,
      reader,
      "workspace.sync.result",
    );
    if (
      syncResult.executionWorkspaceId !== workspaceId ||
      syncResult.workspaceRuntimeId !== runtimeId ||
      syncResult.correlationId !== syncRequestId
    ) {
      throw new Error("Production Gateway sync response identity mismatch");
    }
    return socket;
  } catch (error) {
    socket.destroy();
    throw error;
  }
}

async function waitForSessionRecord() {
  for (let attempt = 0; attempt < 10; attempt += 1) {
    const result = executeD1(
      `SELECT id FROM workspace_sessions WHERE workspace_id = ${sqlString(workspaceId)} AND runtime_identity_id = ${sqlString(runtimeId)} AND disconnected_at IS NULL LIMIT 1`,
    );
    if (rowsFromD1(result).length > 0) return;
    await new Promise((resolve) => setTimeout(resolve, 1_000));
  }
  throw new Error(
    "Gateway connected but did not persist its production session row",
  );
}

function createDisposableRuntime() {
  const now = new Date().toISOString();
  const email = `gateway-smoke-${runId}@example.invalid`;
  executeD1(
    `INSERT INTO users (id, email, display_name, status, created_at, updated_at) VALUES (${sqlString(ownerId)}, ${sqlString(email)}, 'Production Gateway Smoke', 'active', ${sqlString(now)}, ${sqlString(now)});
     INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES (${sqlString(workspaceId)}, ${sqlString(ownerId)}, 'Production Gateway Smoke', 'enrolled', ${sqlString(now)}, ${sqlString(now)});
     INSERT INTO workspace_runtime_identities (id, workspace_id, credential_key_ref, credential_token_hash, created_at) VALUES (${sqlString(runtimeId)}, ${sqlString(workspaceId)}, 'deployment-smoke', ${sqlString(tokenHash)}, ${sqlString(now)});`,
  );
}

function removeDisposableRuntime() {
  executeD1(
    `DELETE FROM execution_workspaces WHERE id = ${sqlString(workspaceId)};
     DELETE FROM users WHERE id = ${sqlString(ownerId)};`,
  );
}

async function main() {
  if (process.argv.includes("--cleanup-only")) {
    removeDisposableRuntime();
    return;
  }

  const requiredTables = new Set(
    rowsFromD1(
      executeD1(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('workspace_sessions', 'workspace_runtime_facts', 'workspace_runtime_identities')",
      ),
    ).map((row) => row.name),
  );
  for (const table of [
    "workspace_sessions",
    "workspace_runtime_facts",
    "workspace_runtime_identities",
  ]) {
    if (!requiredTables.has(table)) {
      throw new Error(
        `Production D1 is missing required Gateway table: ${table}`,
      );
    }
  }

  let socket;
  let setupAttempted = false;
  try {
    setupAttempted = true;
    createDisposableRuntime();
    socket = await connectAndHello();
    await waitForSessionRecord();
    console.log(
      "PASS production Gateway smoke: HTTP 101, hello.ack, sync result, session persisted",
    );
  } finally {
    socket?.end(maskedFrame(Buffer.from([0x03, 0xe8]), 0x8));
    if (setupAttempted) removeDisposableRuntime();
  }
}

main().catch((error) => {
  console.error(`FAIL production Workspace Gateway smoke: ${error.message}`);
  process.exitCode = 1;
});
