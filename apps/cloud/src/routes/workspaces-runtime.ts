import { logStructured, requestIdFor } from "../observability.js";

import { extractBearerToken, hashToken } from "@conclave/security";

import { json } from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";

export async function handleWorkspaceGatewayConnect(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const requestId = requestIdFor(request);
  const url = new URL(request.url);
  const workspaceRuntimeId = url.searchParams.get("workspaceRuntimeId");
  const upgradeHeaderPresent =
    request.headers.get("Upgrade")?.toLowerCase() === "websocket";
  const authorizationPresent = request.headers.has("Authorization");
  logStructured(
    "info",
    "GW-01 workspace_gateway_request_received",
    { requestId },
    {
      method: request.method,
      path: url.pathname,
      upgradeHeaderPresent,
      runtimeIdPresent: Boolean(workspaceRuntimeId),
      authorizationPresent,
    },
  );

  if (!upgradeHeaderPresent) {
    logStructured(
      "warn",
      "GW-01 workspace_gateway_upgrade_rejected",
      { requestId },
      { reason: "upgrade_header_missing" },
    );
    return json({ error: "Expected WebSocket upgrade" }, { status: 426 });
  }

  const authToken =
    extractBearerToken(request.headers) ??
    url.searchParams.get("token") ??
    url.searchParams.get("authToken");

  if (!workspaceRuntimeId || !authToken) {
    logStructured(
      "warn",
      "GW-02 runtime_authentication_not_started",
      { requestId },
      {
        runtimeIdPresent: Boolean(workspaceRuntimeId),
        credentialPresent: Boolean(authToken),
      },
    );
    return json(
      { error: "workspaceRuntimeId and authToken are required" },
      { status: 401 },
    );
  }

  logStructured("info", "GW-02 runtime_authentication_started", {
    requestId,
    runtimeId: workspaceRuntimeId,
  });
  let workspace: { workspaceId: string } | null;
  try {
    const tokenHash = await hashToken(authToken);
    workspace = await env.CONCLAVE_DB.prepare(
      `SELECT wri.workspace_id AS workspaceId
       FROM workspace_runtime_identities wri
       JOIN execution_workspaces ew ON ew.id = wri.workspace_id
       WHERE wri.id = ?1 AND wri.credential_token_hash = ?2
         AND wri.revoked_at IS NULL AND ew.status <> 'revoked'`,
    )
      .bind(workspaceRuntimeId, tokenHash)
      .first<{ workspaceId: string }>();
  } catch (error) {
    logStructured(
      "error",
      "GW-03 runtime_authentication_failed",
      { requestId, runtimeId: workspaceRuntimeId },
      { reason: "credential_lookup_failed" },
    );
    throw error;
  }

  if (!workspace) {
    logStructured(
      "warn",
      "GW-03 runtime_authentication_failed",
      { requestId, runtimeId: workspaceRuntimeId },
      { reason: "invalid_or_revoked_credential" },
    );
    return json(
      { error: "Invalid or revoked Workspace runtime credential" },
      { status: 401 },
    );
  }
  logStructured("info", "GW-03 runtime_authenticated", {
    requestId,
    runtimeId: workspaceRuntimeId,
    workspaceId: workspace.workspaceId,
  });

  if (!env.CONCLAVE_WORKSPACE_GATEWAY) {
    logStructured(
      "error",
      "GW-04 workspace_gateway_forward_rejected",
      {
        requestId,
        runtimeId: workspaceRuntimeId,
        workspaceId: workspace.workspaceId,
      },
      { reason: "gateway_binding_missing" },
    );
    return json(
      { error: "Workspace Gateway is not configured" },
      { status: 503 },
    );
  }
  const stub = env.CONCLAVE_WORKSPACE_GATEWAY.getByName(workspace.workspaceId);
  logStructured("info", "GW-04 forwarding_to_workspace_gateway_do", {
    requestId,
    runtimeId: workspaceRuntimeId,
    workspaceId: workspace.workspaceId,
  });
  try {
    // Preserve the original upgrade Request. CF-Ray is already part of it and
    // is used as the shared request ID by the Durable Object.
    const response = await stub.fetch(request);
    logStructured(
      response.status === 101 ? "info" : "warn",
      "GW-04 workspace_gateway_do_response_received",
      {
        requestId,
        runtimeId: workspaceRuntimeId,
        workspaceId: workspace.workspaceId,
      },
      { status: response.status },
    );
    return response;
  } catch (error) {
    logStructured(
      "error",
      "GW-04 workspace_gateway_forward_failed",
      {
        requestId,
        runtimeId: workspaceRuntimeId,
        workspaceId: workspace.workspaceId,
      },
      {
        errorName: error instanceof Error ? error.name : "UnknownError",
      },
    );
    throw error;
  }
}

export async function handleWorkspaceRuntimeTransport(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  if (!env.CONCLAVE_WORKSPACE_GATEWAY)
    return json(
      { error: "Workspace Gateway is not configured" },
      { status: 503 },
    );
  const url = new URL(request.url);
  const body = (await request.json().catch(() => null)) as Record<
    string,
    unknown
  > | null;
  if (!body) return json({ error: "Invalid request body" }, { status: 400 });
  const authToken = extractBearerToken(request.headers);
  if (!authToken)
    return json(
      { error: "Workspace runtime credential required" },
      { status: 401 },
    );
  let workspaceId: string | null = null;
  if (url.pathname === "/api/workspace-runtime/sessions") {
    if (typeof body.workspaceRuntimeId !== "string")
      return json({ error: "workspaceRuntimeId is required" }, { status: 400 });
    const authorized = await env.CONCLAVE_DB.prepare(
      `SELECT wri.workspace_id AS workspaceId FROM workspace_runtime_identities wri
       JOIN execution_workspaces ew ON ew.id = wri.workspace_id
       WHERE wri.id = ?1 AND wri.credential_token_hash = ?2
       AND wri.revoked_at IS NULL AND ew.status <> 'revoked'`,
    )
      .bind(body.workspaceRuntimeId, await hashToken(authToken))
      .first<{ workspaceId: string }>();
    workspaceId = authorized?.workspaceId ?? null;
  } else {
    if (typeof body.sessionId !== "string")
      return json({ error: "sessionId is required" }, { status: 400 });
    const session = await env.CONCLAVE_DB.prepare(
      "SELECT workspace_id AS workspaceId FROM workspace_sessions WHERE id = ?1 AND disconnected_at IS NULL",
    )
      .bind(body.sessionId)
      .first<{ workspaceId: string }>();
    workspaceId = session?.workspaceId ?? null;
  }
  if (!workspaceId)
    return json(
      { error: "Runtime session not found or credential revoked" },
      { status: 401 },
    );
  const stub = env.CONCLAVE_WORKSPACE_GATEWAY.getByName(workspaceId);
  let internalPath = "/runtime/" + url.pathname.split("/").pop();
  if (url.pathname === "/api/workspace-runtime/sessions")
    internalPath = "/runtime/sessions";
  else if (url.pathname.endsWith("/close")) internalPath = "/runtime/close";
  const forwarded = new Request(
    `https://workspace-gateway.internal${internalPath}`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${authToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    },
  );
  return stub.fetch(forwarded);
}
