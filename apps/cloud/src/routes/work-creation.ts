import {
  validateWorkRequest,
  validateBuiltinWorkflowDefinition,
  BUILTIN_WORKFLOWS,
  type WorkRequest,
  type WorkRequestSnapshot,
  type WorkstreamExecutionPolicy,
  type BuiltinWorkflowDefinition,
  type WorkflowId,
} from "@conclave/core";

import { createEventPublisher } from "../event-publisher.js";
import {
  HttpError,
  authorizeWorkstreamAccess,
  eligibilityMessage,
  errorMessage,
  json,
  parseJson,
  requiredString,
  resolveWorkflowInstanceId,
  validateWorkflowWorkerEligibility,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";
import type { ConclaveWorkflowParams } from "../workflow.js";

export async function createOrGetRun(
  env: Env,
  params: ConclaveWorkflowParams,
): Promise<{ id: string; status: unknown }> {
  const id = await resolveWorkflowInstanceId(
    env,
    params.runId,
    params.idempotencyKey,
  );
  try {
    const instance = await env.CONCLAVE_RUN_WORKFLOW.create({ id, params });
    return { id: params.runId, status: (await instance.status()).status };
  } catch (error) {
    if (!errorMessage(error).toLowerCase().includes("exist")) throw error;
    const instance = await env.CONCLAVE_RUN_WORKFLOW.get(id);
    return { id: params.runId, status: (await instance.status()).status };
  }
}

export async function handleValidateWorkRequest(
  request: Request,
  env: SecurityEnv,
  workstreamId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { context, projectId } = await authorizeWorkstreamAccess(
    request,
    env,
    workstreamId,
    "execute",
    accessContext,
  );
  const membership = await env.CONCLAVE_DB.prepare(
    "SELECT role FROM project_memberships WHERE project_id = ?1 AND user_id = ?2",
  )
    .bind(projectId, context.userId)
    .first<{ role: "owner" | "collaborator" | "viewer" }>();
  if (
    !membership ||
    (membership.role !== "owner" && membership.role !== "collaborator")
  )
    throw new HttpError(
      403,
      "Only a Project owner or collaborator with Work execution access can submit Work",
    );
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT wc.config_json AS configJson FROM workstreams ws
       LEFT JOIN workstream_work_configs wc ON wc.workstream_id = ws.id WHERE ws.id = ?1`,
  )
    .bind(workstreamId)
    .first<{ configJson: string | null }>();
  const config = parseJson<Record<string, unknown>>(row?.configJson, {
    defaultWorkflowId: "full_cycle",
    bindings: {},
  });
  const body = (await request.json()) as Record<string, unknown>;
  const workflowId = requiredString(
    body.workflowId ?? config.defaultWorkflowId,
    "workflowId",
  ) as WorkflowId;
  const workflow = BUILTIN_WORKFLOWS[workflowId];
  if (!workflow) throw new HttpError(400, "Unsupported workflowId");
  if (body.attachments !== undefined && !Array.isArray(body.attachments)) {
    throw new HttpError(400, "attachments must be an array");
  }
  const attachments = Array.isArray(body.attachments) ? body.attachments : [];
  if (attachments.length > 10)
    throw new HttpError(400, "At most 10 attachments are allowed");
  const rawBindings =
    config.bindings &&
    typeof config.bindings === "object" &&
    !Array.isArray(config.bindings)
      ? (config.bindings as Record<string, unknown>)
      : {};
  const bindings: Record<string, { workerId?: string; model?: string }> = {};
  for (const [key, value] of Object.entries(rawBindings)) {
    if (!value || typeof value !== "object" || Array.isArray(value)) continue;
    const candidate = value as Record<string, unknown>;
    bindings[key] = {
      ...(typeof candidate.workerId === "string"
        ? { workerId: candidate.workerId }
        : {}),
      ...(typeof candidate.model === "string"
        ? { model: candidate.model }
        : {}),
    };
  }
  const { issues } = await validateWorkflowWorkerEligibility(
    env,
    projectId,
    workstreamId,
    workflow,
    bindings,
    attachments,
  );
  if (
    !env.CONCLAVE_WORKSTREAM_COORDINATOR &&
    workflow.steps.some((step) => step.executionMode === "stateful_workstream")
  ) {
    issues.push({
      stepKind: workflow.steps[0]?.kind ?? "implement",
      workerTypeId: null,
      code: "runtime_coordinator_unavailable",
      message: eligibilityMessage(
        "Work",
        null,
        "runtime_coordinator_unavailable",
      ),
    });
  }
  return json({
    eligible: issues.length === 0,
    workflowId,
    workflowName: workflow.name,
    issues,
  });
}

export async function handleCreateWorkRequest(
  request: Request,
  env: SecurityEnv,
  workstreamId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { context, projectId } = await authorizeWorkstreamAccess(
    request,
    env,
    workstreamId,
    "execute",
    accessContext,
  );
  const membership = await env.CONCLAVE_DB.prepare(
    "SELECT role FROM project_memberships WHERE project_id = ?1 AND user_id = ?2",
  )
    .bind(projectId, context.userId)
    .first<{ role: "owner" | "collaborator" | "viewer" }>();
  if (
    !membership ||
    (membership.role !== "owner" && membership.role !== "collaborator")
  )
    throw new HttpError(
      403,
      "Only a Project owner or collaborator with Work execution access can submit Work",
    );
  const body = (await request.json()) as Record<string, unknown>;
  const requestedMode =
    body.mode === "stateful"
      ? "stateful"
      : body.mode === "stateless"
        ? "stateless"
        : null;
  const workConfigRow = await env.CONCLAVE_DB.prepare(
    `SELECT wc.config_json AS configJson, p.settings_json AS settingsJson
     FROM workstreams ws
     JOIN projects p ON p.id = ws.project_id
     LEFT JOIN workstream_work_configs wc ON wc.workstream_id = ws.id
     WHERE ws.id = ?1`,
  )
    .bind(workstreamId)
    .first<{ configJson: string | null; settingsJson: string | null }>();
  const workConfig = parseJson<Record<string, unknown>>(
    workConfigRow?.configJson,
    { defaultWorkflowId: "full_cycle", bindings: {} },
  );
  const workflowId = requiredString(
    body.workflowId ?? workConfig.defaultWorkflowId,
    "workflowId",
  ) as WorkflowId;
  const canonicalWorkflow = BUILTIN_WORKFLOWS[workflowId];
  if (!canonicalWorkflow) throw new HttpError(400, "Unsupported workflowId");
  const mode =
    workflowId === "direct"
      ? "stateful"
      : canonicalWorkflow.steps.some(
            (step) => step.executionMode === "stateful_workstream",
          )
        ? "stateful"
        : "stateless";
  if (requestedMode && requestedMode !== mode) {
    throw new HttpError(
      400,
      `The ${workflowId} Workflow requires ${mode} mode`,
    );
  }
  const workflowVersion = Number(
    body.workflowVersion ?? canonicalWorkflow.version,
  );
  if (!Number.isInteger(workflowVersion) || workflowVersion < 1)
    throw new HttpError(400, "workflowVersion must be a positive integer");
  const snapshotValue = body.workflowSnapshot ?? canonicalWorkflow;
  if (!snapshotValue || typeof snapshotValue !== "object")
    throw new HttpError(400, "workflowSnapshot is invalid");
  const workflowSnapshot = snapshotValue as BuiltinWorkflowDefinition;
  try {
    validateBuiltinWorkflowDefinition(workflowSnapshot);
    if (
      workflowSnapshot.id !== workflowId ||
      workflowSnapshot.version !== workflowVersion
    )
      throw new Error(
        "Workflow snapshot does not match the selected built-in version",
      );
  } catch (error) {
    throw new HttpError(
      400,
      error instanceof Error ? error.message : "Invalid built-in Workflow",
    );
  }
  const submittedInput =
    body.input && typeof body.input === "object" && !Array.isArray(body.input)
      ? (body.input as Record<string, unknown>)
      : {};
  const originalRequest =
    [
      submittedInput.originalRequest,
      submittedInput.request,
      submittedInput.objective,
      body.originalRequest,
      body.request,
      body.objective,
    ].find(
      (value): value is string =>
        typeof value === "string" && value.trim().length > 0,
    ) ?? "";
  const requestInput: Record<string, unknown> = {
    ...submittedInput,
    originalRequest:
      typeof submittedInput.originalRequest === "string"
        ? submittedInput.originalRequest
        : originalRequest,
  };
  const submittedAttachments = submittedInput.attachments ?? body.attachments;
  if (
    submittedAttachments !== undefined &&
    !Array.isArray(submittedAttachments)
  ) {
    throw new HttpError(400, "attachments must be an array");
  }
  const rawAttachments = Array.isArray(submittedAttachments)
    ? submittedAttachments
    : [];
  if (rawAttachments.length > 10)
    throw new HttpError(400, "At most 10 attachments are allowed");
  let attachmentBytes = 0;
  const normalizedAttachments = rawAttachments.map((attachment, index) => {
    if (
      !attachment ||
      typeof attachment !== "object" ||
      Array.isArray(attachment)
    )
      throw new HttpError(400, `Attachment ${index + 1} is invalid`);
    const value = attachment as Record<string, unknown>;
    const kind =
      value.kind === "url" ? "url" : value.kind === "file" ? "file" : null;
    const name =
      typeof value.name === "string"
        ? value.name.replace(/[\\/\\x00-\\x1f]/g, "_").slice(0, 255)
        : "Attachment";
    const mediaType =
      typeof value.mediaType === "string" && value.mediaType.length <= 128
        ? value.mediaType
        : "application/octet-stream";
    if (!kind)
      throw new HttpError(
        400,
        `Attachment ${index + 1} has an unsupported type`,
      );
    if (kind === "url") {
      if (typeof value.url !== "string" || value.url.length > 2048)
        throw new HttpError(400, `Link ${index + 1} is invalid`);
      let url: URL;
      try {
        url = new URL(value.url);
      } catch {
        throw new HttpError(400, `Link ${index + 1} is invalid`);
      }
      if (
        (url.protocol !== "http:" && url.protocol !== "https:") ||
        url.username ||
        url.password
      )
        throw new HttpError(
          400,
          `Link ${index + 1} must be an http or https URL without embedded credentials`,
        );
      return {
        kind,
        name,
        mediaType: "text/uri-list",
        sizeBytes: 0,
        url: url.toString(),
      };
    }
    if (
      typeof value.contentBase64 !== "string" ||
      !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(
        value.contentBase64,
      )
    )
      throw new HttpError(400, `File ${index + 1} is invalid`);
    let decodedLength: number;
    try {
      decodedLength = atob(value.contentBase64).length;
    } catch {
      throw new HttpError(400, `File ${index + 1} is invalid`);
    }
    if (decodedLength > 1024 * 1024 || value.sizeBytes !== decodedLength)
      throw new HttpError(
        400,
        `File ${index + 1} exceeds the 1 MB limit or has an invalid size`,
      );
    attachmentBytes += decodedLength;
    if (attachmentBytes > 1024 * 1024)
      throw new HttpError(400, "Attachments exceed the 1 MB total limit");
    return {
      kind,
      name,
      mediaType,
      sizeBytes: decodedLength,
      contentBase64: value.contentBase64,
    };
  });
  requestInput.attachments = normalizedAttachments;
  const attachmentReferences = normalizedAttachments.map(
    ({ contentBase64: _contentBase64, ...reference }) => reference,
  );
  const configuredBindings =
    workConfig.bindings &&
    typeof workConfig.bindings === "object" &&
    !Array.isArray(workConfig.bindings)
      ? (workConfig.bindings as Record<string, unknown>)
      : {};
  const resolvedBindings: Record<
    string,
    {
      workerId?: string;
      model?: string;
      fallbackWorkerId?: string;
      additionalInstructions?: string;
    }
  > = {};
  const stepAdditionalInstructions: WorkRequestSnapshot["stepAdditionalInstructions"] =
    {};
  const promptProfileVersions: WorkRequestSnapshot["promptProfileVersions"] =
    {};
  for (const step of workflowSnapshot.steps) {
    const bindingId = workflowId === "direct" ? "direct" : step.kind;
    const rawBinding = configuredBindings[bindingId];
    const configuredBinding =
      rawBinding && typeof rawBinding === "object" && !Array.isArray(rawBinding)
        ? (rawBinding as Record<string, unknown>)
        : {};
    const resolvedBinding: {
      workerId?: string;
      model?: string;
      fallbackWorkerId?: string;
      additionalInstructions?: string;
    } = {};
    if (typeof configuredBinding.workerId === "string") {
      resolvedBinding.workerId = configuredBinding.workerId;
    }
    if (typeof configuredBinding.model === "string") {
      resolvedBinding.model = configuredBinding.model;
    }
    if (typeof configuredBinding.fallbackWorkerId === "string") {
      resolvedBinding.fallbackWorkerId = configuredBinding.fallbackWorkerId;
    }
    if (typeof configuredBinding.additionalInstructions === "string") {
      resolvedBinding.additionalInstructions =
        configuredBinding.additionalInstructions;
      stepAdditionalInstructions[step.kind] =
        configuredBinding.additionalInstructions;
    }
    resolvedBindings[bindingId] = resolvedBinding;
    promptProfileVersions[step.kind] = step.promptProfileVersion;
  }
  const eligibility = await validateWorkflowWorkerEligibility(
    env,
    projectId,
    workstreamId,
    workflowSnapshot,
    resolvedBindings,
    normalizedAttachments,
  );
  if (eligibility.issues.length > 0) {
    return json(
      {
        error: "work_request_ineligible",
        workflowId,
        workflowName: workflowSnapshot.name,
        issues: eligibility.issues,
      },
      { status: 422 },
    );
  }
  if (!env.CONCLAVE_WORKSTREAM_COORDINATOR && mode === "stateful") {
    throw new HttpError(503, "Workstream runtime coordination is unavailable");
  }
  if (eligibility.primaryWorkspaceId) {
    if (
      body.primaryWorkspaceId !== undefined &&
      body.primaryWorkspaceId !== eligibility.primaryWorkspaceId
    ) {
      throw new HttpError(
        400,
        "Work execution must use the selected Worker's Workspace",
      );
    }
    body.primaryWorkspaceId = eligibility.primaryWorkspaceId;
  }
  const projectSettings = parseJson<Record<string, unknown>>(
    workConfigRow?.settingsJson,
    {},
  );
  const projectInstructions =
    typeof projectSettings.instructions === "string"
      ? projectSettings.instructions
      : "";
  const workstreamInstructions =
    typeof workConfig.workstreamInstructions === "string"
      ? workConfig.workstreamInstructions
      : "";
  const snapshot: WorkRequestSnapshot = {
    schemaVersion: 1,
    originalRequest,
    attachmentReferences,
    workflowId,
    workflowVersion,
    workflowSnapshot,
    resolvedBindings,
    projectInstructions,
    workstreamInstructions,
    stepAdditionalInstructions,
    promptProfileVersions,
  };
  const policyRow = await env.CONCLAVE_DB.prepare(
    "SELECT mode, primary_workspace_id AS primaryWorkspaceId, max_concurrent_work_requests AS maxConcurrentWorkRequests FROM workstream_execution_policies WHERE workstream_id = ?1",
  )
    .bind(workstreamId)
    .first<WorkstreamExecutionPolicy>();
  const policy: WorkstreamExecutionPolicy =
    workflowId === "direct" || workflowId === "research"
      ? {
          mode,
          primaryWorkspaceId:
            typeof body.primaryWorkspaceId === "string"
              ? body.primaryWorkspaceId
              : null,
          maxConcurrentWorkRequests: 1,
        }
      : (policyRow ?? {
          mode,
          primaryWorkspaceId:
            typeof body.primaryWorkspaceId === "string"
              ? body.primaryWorkspaceId
              : null,
          maxConcurrentWorkRequests: 1,
        });
  const now = new Date().toISOString();
  const workRequest: WorkRequest = {
    id: `work-request-${crypto.randomUUID()}`,
    workstreamId,
    requestedByUserId: context.userId,
    mode,
    workflowId,
    workflowVersion,
    workflowSnapshot,
    snapshot,
    status: "queued",
    primaryWorkspaceId:
      typeof body.primaryWorkspaceId === "string"
        ? body.primaryWorkspaceId
        : null,
    input: requestInput,
    createdAt: now,
    updatedAt: now,
  };
  try {
    validateWorkRequest(workRequest, policy);
  } catch (error) {
    throw new HttpError(
      400,
      error instanceof Error ? error.message : "Invalid Work Request",
    );
  }
  const runId = `run-${crypto.randomUUID()}`;
  await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      `INSERT INTO work_requests
       (id, workstream_id, requested_by_user_id, mode, workflow_id, workflow_version, workflow_snapshot_json, snapshot_json, status, primary_workspace_id, input_json, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'queued', ?9, ?10, ?11, ?11)`,
    ).bind(
      workRequest.id,
      workstreamId,
      context.userId,
      mode,
      workflowId,
      workflowVersion,
      JSON.stringify(workflowSnapshot),
      JSON.stringify(snapshot),
      workRequest.primaryWorkspaceId,
      JSON.stringify(workRequest.input),
      now,
    ),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO runs
       (id, project_id, workstream_id, work_request_id, status, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, 'created', ?5, ?5)`,
    ).bind(runId, projectId, workstreamId, workRequest.id, now),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO project_audit_log
       (id, project_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
       VALUES (?1, ?2, 'user', ?3, 'workstream.work_requested', 'work_request', ?4, ?5, ?6)`,
    ).bind(
      `pa-${crypto.randomUUID()}`,
      projectId,
      context.userId,
      workRequest.id,
      JSON.stringify({ workstreamId, runId, workflowId, workflowVersion }),
      now,
    ),
  ]);
  try {
    await createEventPublisher(env).publish({
      type: "work_request.created",
      workspaceId: workRequest.primaryWorkspaceId!,
      projectId,
      runId,
      idempotencyKey: `work-request:${workRequest.id}:created`,
      payload: {
        entityId: workRequest.id,
        workRequestId: workRequest.id,
        workstreamId,
        status: "queued",
      },
    });
  } catch (error) {
    console.error("Failed to publish work_request.created", error);
  }
  if (mode === "stateful" && env.CONCLAVE_WORKSTREAM_COORDINATOR) {
    const coordinator =
      env.CONCLAVE_WORKSTREAM_COORDINATOR.getByName(workstreamId);
    const response = await coordinator.fetch(
      new Request("https://workstream-coordinator/enqueue", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-workstream-id": workstreamId,
        },
        body: JSON.stringify({ workRequestId: workRequest.id }),
      }),
    );
    if (!response.ok) {
      throw new HttpError(503, "Workstream execution coordinator unavailable");
    }
  }
  await createOrGetRun(env, {
    runId,
    goalId: workRequest.id,
    idempotencyKey: workRequest.id,
    organizationId: workRequest.primaryWorkspaceId!,
    workRequestId: workRequest.id,
    workstreamId,
    projectId,
    builtinWorkflow: workflowSnapshot,
    input: requestInput,
  });
  return json(
    {
      workRequest,
      run: { id: runId, projectId, workstreamId, status: "created" },
    },
    { status: 202 },
  );
}
