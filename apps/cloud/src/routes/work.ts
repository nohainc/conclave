import {
  cancelTaskAssignment,
  type AssignmentDispatcherEnv,
} from "../assignment-dispatcher.js";
import { type SecurityContext } from "@conclave/security";
import {
  validateWorkRequest,
  validateBuiltinWorkflowDefinition,
  BUILTIN_WORKFLOWS,
  canExecuteWorkstream,
  DEFAULT_WORKSTREAM_ACCESS_POLICY,
  type WorkRequest,
  type WorkRequestSnapshot,
  type ProjectMembership,
  type Workstream,
  type WorkstreamExecutionPolicy,
  type BuiltinWorkflowDefinition,
  type WorkflowId,
  type StepKind,
} from "@conclave/core";
import {
  canonicalExecutionErrorCode,
  executionErrorMessage,
} from "@conclave/protocol";
import { createEventPublisher } from "../event-publisher.js";
import {
  HttpError,
  authorizeRequest,
  authorizeWorkstreamAccess,
  createOrGetRun,
  eligibilityMessage,
  errorMessage,
  goalProjectId,
  json,
  parseJson,
  recordAudit,
  requireCiAuthentication,
  requireForgeCallbackAuthentication,
  requiredString,
  resolveWorkflowInstanceId,
  runProjectId,
  securityContext,
  securityEnv,
  sortWorkstreams,
  summarizeTestCounts,
  testAuthenticationEnabled,
  validateAndClaimCiEvidence,
  validateWorkflowWorkerEligibility,
  workflowInstanceId,
  workstreamMetadata,
} from "./handlers.js";
import type { ConclaveWorkflowParams, SecurityEnv } from "./handlers.js";

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
        "Work execution must use the configured Worker Workspace",
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
    "SELECT mode, primary_workspace_id AS primaryWorkspaceId, require_checkout AS requireCheckout, max_concurrent_work_requests AS maxConcurrentWorkRequests FROM workstream_execution_policies WHERE workstream_id = ?1",
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
          requireCheckout: false,
          maxConcurrentWorkRequests: 1,
        }
      : (policyRow ?? {
          mode,
          primaryWorkspaceId:
            typeof body.primaryWorkspaceId === "string"
              ? body.primaryWorkspaceId
              : null,
          // WD-17: stateful Work resolves the local ID-derived Workstream directory;
          // legacy checkout provisioning is not part of the active request path.
          requireCheckout: false,
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
    // Ignore the historical client field. Runtime CWD is derived from the
    // immutable Project/Workstream IDs on the Workspace.
    checkoutId: null,
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
       (id, workstream_id, requested_by_user_id, mode, workflow_id, workflow_version, workflow_snapshot_json, snapshot_json, status, primary_workspace_id, checkout_id, input_json, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'queued', ?9, ?10, ?11, ?12, ?12)`,
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
      workRequest.checkoutId,
      JSON.stringify(workRequest.input),
      now,
    ),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO runs
       (id, project_id, workstream_id, work_request_id, checkout_id, status, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, 'created', ?6, ?6)`,
    ).bind(
      runId,
      projectId,
      workstreamId,
      workRequest.id,
      workRequest.checkoutId,
      now,
    ),
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

export async function handleRetryWorkRequest(
  request: Request,
  env: SecurityEnv,
  workRequestId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const parent = await env.CONCLAVE_DB.prepare(
    "SELECT workstream_id AS workstreamId FROM work_requests WHERE id = ?1",
  )
    .bind(workRequestId)
    .first<{ workstreamId: string }>();
  if (!parent) throw new HttpError(404, "Work Request not found");
  const { context, projectId } = await authorizeWorkstreamAccess(
    request,
    env,
    parent.workstreamId,
    "execute",
    accessContext,
  );
  const membership = await env.CONCLAVE_DB.prepare(
    "SELECT role FROM project_memberships WHERE project_id = ?1 AND user_id = ?2",
  )
    .bind(projectId, context.userId)
    .first<{ role: string }>();
  if (!membership || membership.role === "viewer")
    throw new HttpError(
      403,
      "Project membership with execute access is required",
    );
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT wr.workstream_id AS workstreamId, wr.mode, wr.status,
            wr.workflow_id AS workflowId, wr.workflow_version AS workflowVersion,
            wr.workflow_snapshot_json AS workflowSnapshotJson,
            wr.snapshot_json AS snapshotJson, wr.input_json AS inputJson,
            wr.primary_workspace_id AS primaryWorkspaceId,
            ws.project_id AS projectId
       FROM work_requests wr JOIN workstreams ws ON ws.id = wr.workstream_id
      WHERE wr.id = ?1`,
  )
    .bind(workRequestId)
    .first<Record<string, unknown>>();
  if (!row) throw new HttpError(404, "Work Request not found");
  if (row.status !== "failed")
    throw new HttpError(409, "Only a failed Work Request can be retried");

  const body = parseJson<Record<string, unknown>>(await request.text(), {});
  const stepKind = body.stepKind;
  if (
    typeof stepKind !== "string" ||
    !["research", "plan", "implement", "test", "verify"].includes(stepKind)
  )
    throw new HttpError(400, "A valid failed Step is required");
  const workflow = parseJson<BuiltinWorkflowDefinition>(
    String(row.workflowSnapshotJson),
    {} as BuiltinWorkflowDefinition,
  );
  const step = workflow.steps?.find((candidate) => candidate.kind === stepKind);
  if (!step) throw new HttpError(400, "Step is not part of this Workflow");
  const failedTask = await env.CONCLAVE_DB.prepare(
    `SELECT wt.status, wt.error,
            (SELECT wa.error_json FROM worker_assignments wa
              WHERE wa.task_id = wt.id ORDER BY wa.created_at DESC, wa.id DESC LIMIT 1)
              AS assignmentErrorJson
       FROM workflow_tasks wt
      WHERE wt.work_request_id = ?1 AND wt.step_kind = ?2`,
  )
    .bind(workRequestId, stepKind)
    .first<{
      status: string;
      error: string | null;
      assignmentErrorJson: string | null;
    }>();
  if (failedTask?.status !== "failed")
    throw new HttpError(409, "Only a failed Step can be retried");

  const retrySessionStrategy = body.sessionStrategy;
  if (
    stepKind === "implement" &&
    retrySessionStrategy !== "resume" &&
    retrySessionStrategy !== "fresh"
  )
    throw new HttpError(
      400,
      "Choose whether the Implement retry resumes the previous session or starts fresh",
    );
  if (stepKind !== "implement" && retrySessionStrategy !== undefined)
    throw new HttpError(400, "Session strategy only applies to Implement");

  const snapshot = parseJson<Record<string, unknown>>(
    String(row.snapshotJson),
    {},
  );
  const bindings =
    typeof snapshot.resolvedBindings === "object" &&
    snapshot.resolvedBindings !== null
      ? (snapshot.resolvedBindings as Record<
          string,
          { workerId?: string; model?: string }
        >)
      : {};
  const attachmentInput = parseJson<Record<string, unknown>>(
    String(row.inputJson),
    {},
  );
  const eligibility = await validateWorkflowWorkerEligibility(
    env,
    String(row.projectId),
    String(row.workstreamId),
    { ...workflow, steps: [step] },
    bindings,
    Array.isArray(attachmentInput.attachments)
      ? attachmentInput.attachments
      : [],
  );
  if (eligibility.issues.length > 0) {
    return json(
      { error: "work_request_ineligible", issues: eligibility.issues },
      { status: 422 },
    );
  }

  const latestRuns = await env.CONCLAVE_DB.prepare(
    "SELECT COUNT(*) AS count FROM runs WHERE work_request_id = ?1",
  )
    .bind(workRequestId)
    .first<{ count: number }>();
  const retryNumber = Math.max(1, Number(latestRuns?.count ?? 1));
  const runId = `run-${workRequestId}-retry-${retryNumber}`;
  const now = new Date().toISOString();
  const assignmentError = parseJson<Record<string, unknown>>(
    failedTask.assignmentErrorJson,
    {},
  );
  const assignmentErrorDetail =
    typeof assignmentError.error === "object" && assignmentError.error !== null
      ? (assignmentError.error as Record<string, unknown>)
      : {};
  const errorCode = canonicalExecutionErrorCode(
    assignmentErrorDetail.code ?? failedTask.error ?? "execution_failed",
  );
  const retryPolicy = {
    manualRetry: {
      stepKind,
      errorCode,
      retryNumber,
      ...(stepKind === "implement"
        ? { sessionStrategy: retrySessionStrategy }
        : {}),
    },
  };
  const reservation = await env.CONCLAVE_DB.prepare(
    "UPDATE work_requests SET status = 'queued', updated_at = ?1 WHERE id = ?2 AND status = 'failed'",
  )
    .bind(now, workRequestId)
    .run();
  if (reservation.meta.changes !== 1)
    throw new HttpError(409, "This Work Request is already being retried");
  try {
    await env.CONCLAVE_DB.batch([
      env.CONCLAVE_DB.prepare(
        `UPDATE workflow_tasks SET status = 'queued', output_json = NULL,
              error = NULL, started_at = NULL, finished_at = NULL, updated_at = ?1
        WHERE work_request_id = ?2 AND step_kind = ?3 AND status = 'failed'`,
      ).bind(now, workRequestId, stepKind),
      env.CONCLAVE_DB.prepare(
        `INSERT INTO runs
       (id, project_id, workstream_id, work_request_id, checkout_id,
        policy_snapshot_json, status, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, NULL, ?5, 'created', ?6, ?6)`,
      ).bind(
        runId,
        projectId,
        String(row.workstreamId),
        workRequestId,
        JSON.stringify(retryPolicy),
        now,
      ),
    ]);
  } catch (error) {
    await env.CONCLAVE_DB.prepare(
      "UPDATE work_requests SET status = 'failed', updated_at = ?1 WHERE id = ?2 AND status = 'queued'",
    )
      .bind(new Date().toISOString(), workRequestId)
      .run();
    throw error;
  }

  if (row.mode === "stateful") {
    if (!env.CONCLAVE_WORKSTREAM_COORDINATOR)
      throw new HttpError(
        503,
        "Workstream runtime coordination is unavailable",
      );
    const coordinator = env.CONCLAVE_WORKSTREAM_COORDINATOR.getByName(
      String(row.workstreamId),
    );
    const response = await coordinator.fetch(
      new Request("https://workstream-coordinator/enqueue", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-workstream-id": String(row.workstreamId),
        },
        body: JSON.stringify({ workRequestId }),
      }),
    );
    if (!response.ok)
      throw new HttpError(
        503,
        "Workstream runtime coordination is unavailable",
      );
  }

  await createOrGetRun(env, {
    runId,
    goalId: workRequestId,
    idempotencyKey: `${workRequestId}-retry-${retryNumber}`,
    organizationId: String(row.primaryWorkspaceId),
    workRequestId,
    workstreamId: String(row.workstreamId),
    projectId,
    builtinWorkflow: workflow,
    input: attachmentInput,
    retryStepKind: stepKind as StepKind,
    ...(stepKind === "implement"
      ? { retrySessionStrategy: retrySessionStrategy as "resume" | "fresh" }
      : {}),
    retryNumber,
  });
  return json(
    { workRequestId, runId, stepKind, retryNumber, status: "queued" },
    { status: 202 },
  );
}

export async function handleGetWorkRequest(
  request: Request,
  env: SecurityEnv,
  workRequestId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT wr.id, wr.workstream_id AS workstreamId,
            wr.requested_by_user_id AS requestedByUserId,
            u.display_name AS requestedByName,
            wr.workflow_id AS workflowId, wr.workflow_version AS workflowVersion,
            wr.workflow_snapshot_json AS workflowSnapshotJson,
            wr.input_json AS inputJson, wr.snapshot_json AS snapshotJson,
            wr.status, wr.created_at AS createdAt, wr.updated_at AS updatedAt
       FROM work_requests wr JOIN users u ON u.id = wr.requested_by_user_id
      WHERE wr.id = ?1`,
  )
    .bind(workRequestId)
    .first<Record<string, unknown>>();
  if (!row) throw new HttpError(404, "Work Request not found");
  await authorizeWorkstreamAccess(
    request,
    env,
    String(row.workstreamId),
    "view",
    accessContext,
  );
  const task = await env.CONCLAVE_DB.prepare(
    `SELECT output_json AS outputJson, error
     FROM workflow_tasks WHERE work_request_id = ?1
     ORDER BY created_at DESC, id DESC LIMIT 1`,
  )
    .bind(workRequestId)
    .first<{ outputJson: string | null; error: string | null }>();
  let result: unknown = null;
  if (task?.outputJson) {
    try {
      result = JSON.parse(task.outputJson);
    } catch {
      result = null;
    }
  }
  const input = parseJson<Record<string, unknown>>(String(row.inputJson), {});
  const snapshot = parseJson<Record<string, unknown>>(
    String(row.snapshotJson),
    {},
  );
  const workflow = parseJson<Record<string, unknown>>(
    String(row.workflowSnapshotJson),
    {},
  );
  const latestRun = await env.CONCLAVE_DB.prepare(
    `SELECT policy_snapshot_json AS policySnapshotJson
       FROM runs WHERE work_request_id = ?1
      ORDER BY created_at DESC, id DESC LIMIT 1`,
  )
    .bind(workRequestId)
    .first<{ policySnapshotJson: string | null }>();
  const latestRunPolicy = parseJson<Record<string, unknown>>(
    latestRun?.policySnapshotJson,
    {},
  );
  const manualRetry =
    typeof latestRunPolicy.manualRetry === "object" &&
    latestRunPolicy.manualRetry !== null
      ? (latestRunPolicy.manualRetry as Record<string, unknown>)
      : {};
  const bindings =
    typeof snapshot.resolvedBindings === "object" &&
    snapshot.resolvedBindings !== null
      ? (snapshot.resolvedBindings as Record<string, unknown>)
      : {};
  const taskRows = await env.CONCLAVE_DB.prepare(
    `SELECT wt.id AS taskId, wt.step_kind AS kind, wt.status,
            wt.output_json AS outputJson, wt.error, wt.attempt,
            wt.started_at AS startedAt, wt.finished_at AS finishedAt,
            wa.id AS assignmentId, wa.workspace_worker_id AS workerId,
            wa.worker_id AS logicalWorkerTypeId, wa.model AS assignedModel,
            wa.engine_version AS engineVersion,
            wa.session_policy AS sessionPolicy,
            wa.created_at AS assignmentCreatedAt,
            wa.updated_at AS assignmentUpdatedAt,
            wa.permission_snapshot_json AS permissionSnapshotJson,
            wa.error_json AS assignmentErrorJson,
            wi.worker_type_id AS configuredWorkerTypeId,
            wi.provider_tool_name AS configuredProviderToolName,
            wi.provider_tool_version AS configuredProviderToolVersion
       FROM workflow_tasks wt
       JOIN work_requests wr ON wr.id = wt.work_request_id
       LEFT JOIN worker_assignments wa ON wa.id = (
         SELECT wa2.id FROM worker_assignments wa2
          WHERE wa2.task_id = wt.id
          ORDER BY wa2.created_at DESC, wa2.id DESC LIMIT 1
       )
       LEFT JOIN workspace_worker_inventory wi ON wi.worker_id = COALESCE(
         wa.workspace_worker_id,
         json_extract(wr.snapshot_json, '$.resolvedBindings.' ||
           CASE WHEN wr.workflow_id = 'direct' THEN 'direct' ELSE wt.step_kind END || '.workerId')
       )
      WHERE wt.work_request_id = ?1
      ORDER BY wt.created_at, wt.id`,
  )
    .bind(workRequestId)
    .all<Record<string, unknown>>();
  const taskByKind = new Map(
    (taskRows.results ?? []).map((value) => [String(value.kind), value]),
  );
  const workflowSteps = Array.isArray(workflow.steps) ? workflow.steps : [];
  const steps = workflowSteps.flatMap((value) => {
    if (!value || typeof value !== "object") return [];
    const definition = value as Record<string, unknown>;
    const kind = String(definition.kind ?? "implement");
    const task = taskByKind.get(kind);
    const bindingId = row.workflowId === "direct" ? "direct" : kind;
    const bindingValue = bindings[bindingId];
    const binding =
      typeof bindingValue === "object" && bindingValue !== null
        ? (bindingValue as Record<string, unknown>)
        : {};
    const output = parseJson<Record<string, unknown>>(
      typeof task?.outputJson === "string" ? task.outputJson : null,
      {},
    );
    const permissionSnapshot = parseJson<Record<string, unknown>>(
      typeof task?.permissionSnapshotJson === "string"
        ? task.permissionSnapshotJson
        : null,
      {},
    );
    const hasAssignment = typeof task?.assignmentId === "string";
    const assignmentError = parseJson<Record<string, unknown>>(
      typeof task?.assignmentErrorJson === "string"
        ? task.assignmentErrorJson
        : null,
      {},
    );
    const assignmentErrorValue = assignmentError.error;
    const assignmentErrorObject =
      typeof assignmentErrorValue === "object" && assignmentErrorValue !== null
        ? (assignmentErrorValue as Record<string, unknown>)
        : {};
    const rawErrorCode =
      typeof assignmentErrorObject.code === "string"
        ? assignmentErrorObject.code
        : typeof task?.error === "string"
          ? task.error
          : null;
    const errorCode = rawErrorCode
      ? canonicalExecutionErrorCode(rawErrorCode)
      : null;
    const startedAt =
      (typeof task?.startedAt === "string" ? task.startedAt : null) ??
      (typeof output.startedAt === "string" ? output.startedAt : null) ??
      (typeof task?.assignmentCreatedAt === "string"
        ? task.assignmentCreatedAt
        : null);
    const finishedAt =
      (typeof task?.finishedAt === "string" ? task.finishedAt : null) ??
      (typeof output.completedAt === "string" ? output.completedAt : null) ??
      (typeof task?.assignmentUpdatedAt === "string" &&
      ["completed", "failed", "cancelled"].includes(String(task.status))
        ? task.assignmentUpdatedAt
        : null);
    const startMs = startedAt ? Date.parse(startedAt) : NaN;
    const endMs = finishedAt ? Date.parse(finishedAt) : Date.now();
    const elapsedMs = Number.isFinite(startMs)
      ? Math.max(0, endMs - startMs)
      : null;
    const resolvedWorkerId =
      typeof binding.workerId === "string" ? binding.workerId : null;
    return [
      {
        kind,
        status: String(
          task?.status ?? (row.status === "queued" ? "queued" : "waiting"),
        ),
        workerId: task?.workerId ?? resolvedWorkerId,
        workerTypeId: hasAssignment
          ? (task?.logicalWorkerTypeId ?? null)
          : (task?.configuredWorkerTypeId ?? null),
        engineVersion: hasAssignment
          ? typeof permissionSnapshot.profileDefinitionId === "string"
            ? (task?.engineVersion ?? null)
            : null
          : typeof output.engineVersion === "string"
            ? output.engineVersion
            : null,
        profileDefinitionId: hasAssignment
          ? typeof permissionSnapshot.profileDefinitionId === "string"
            ? permissionSnapshot.profileDefinitionId
            : null
          : null,
        profileReleaseVersion: hasAssignment
          ? Number.isSafeInteger(permissionSnapshot.profileReleaseVersion)
            ? permissionSnapshot.profileReleaseVersion
            : null
          : null,
        model: hasAssignment
          ? (task?.assignedModel ?? null)
          : typeof binding.model === "string"
            ? binding.model
            : null,
        providerToolName:
          (typeof permissionSnapshot.providerToolName === "string"
            ? permissionSnapshot.providerToolName
            : null) ??
          (hasAssignment ? null : task?.configuredProviderToolName) ??
          null,
        providerToolVersion:
          (typeof permissionSnapshot.providerToolVersion === "string"
            ? permissionSnapshot.providerToolVersion
            : null) ??
          (hasAssignment ? null : task?.configuredProviderToolVersion) ??
          (typeof output.providerToolVersion === "string"
            ? output.providerToolVersion
            : null),
        startedAt,
        completedAt: finishedAt,
        elapsedMs,
        resultText:
          typeof output.text === "string" ? output.text.slice(0, 24_000) : null,
        assignmentId:
          typeof task?.assignmentId === "string" ? task.assignmentId : null,
        sessionPolicy:
          typeof task?.sessionPolicy === "string" ? task.sessionPolicy : null,
        errorCode,
        errorMessage: errorCode ? executionErrorMessage(errorCode) : null,
        ...(manualRetry.stepKind === kind &&
        (manualRetry.sessionStrategy === "resume" ||
          manualRetry.sessionStrategy === "fresh")
          ? { retrySessionStrategy: manualRetry.sessionStrategy }
          : {}),
      },
    ];
  });
  const errorCode =
    [...steps]
      .reverse()
      .map((step) => step.errorCode)
      .find((code) => code !== null) ?? null;
  return json({
    workRequest: {
      id: String(row.id),
      requestedByUserId: String(row.requestedByUserId),
      requestedByName: String(row.requestedByName ?? "Team member"),
      status: String(row.status),
      workflowId: String(row.workflowId),
      workflowVersion: Number(row.workflowVersion),
      workflowName:
        typeof workflow.name === "string"
          ? workflow.name
          : String(row.workflowId),
      originalRequest: String(input.originalRequest ?? input.request ?? ""),
      createdAt: String(row.createdAt),
      updatedAt: String(row.updatedAt),
    },
    workflowSnapshot: workflow,
    steps,
    result,
    errorCode,
    errorMessage: errorCode ? executionErrorMessage(errorCode) : null,
  });
}

export async function handleListWorkRequests(
  request: Request,
  env: SecurityEnv,
  workstreamId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeWorkstreamAccess(
    request,
    env,
    workstreamId,
    "view",
    accessContext,
  );
  const url = new URL(request.url);
  const rawLimit = Number(url.searchParams.get("limit") ?? 100);
  const limit = Number.isInteger(rawLimit)
    ? Math.min(100, Math.max(1, rawLimit))
    : 100;
  const beforeCreatedAt = url.searchParams.get("beforeCreatedAt");
  const beforeId = url.searchParams.get("beforeId");
  const activeOnly = url.searchParams.get("activeOnly") === "true";
  const recentCutoff = new Date(Date.now() - 15 * 60_000).toISOString();
  const page = await env.CONCLAVE_DB.prepare(
    `SELECT wr.id, wr.requested_by_user_id AS requestedByUserId,
            u.display_name AS requestedByName, wr.workflow_id AS workflowId,
            wr.workflow_version AS workflowVersion,
            wr.workflow_snapshot_json AS workflowSnapshotJson,
            wr.snapshot_json AS snapshotJson, wr.input_json AS inputJson,
            wr.status, wr.created_at AS createdAt, wr.updated_at AS updatedAt
       FROM work_requests wr
       JOIN users u ON u.id = wr.requested_by_user_id
      WHERE wr.workstream_id = ?1
        AND (?2 IS NULL OR wr.created_at < ?2 OR (wr.created_at = ?2 AND wr.id < ?3))
        AND (?4 = 0 OR wr.status IN ('queued', 'running', 'waiting') OR wr.updated_at >= ?5)
      ORDER BY wr.created_at DESC, wr.id DESC LIMIT ?6`,
  )
    .bind(
      workstreamId,
      beforeCreatedAt,
      beforeId,
      activeOnly ? 1 : 0,
      recentCutoff,
      limit,
    )
    .all<Record<string, unknown>>();
  const requests = page.results ?? [];
  if (requests.length === 0)
    return json({ workRequests: [], nextCursor: null });
  const ids = requests.map((row) => String(row.id));
  const placeholders = ids.map((_, index) => `?${index + 1}`).join(", ");
  const desiredWorkerIds = new Set<string>();
  for (const row of requests) {
    const requestSnapshot = parseJson<Record<string, unknown>>(
      typeof row.snapshotJson === "string" ? row.snapshotJson : null,
      {},
    );
    const requestBindings = requestSnapshot.resolvedBindings;
    if (typeof requestBindings !== "object" || requestBindings === null)
      continue;
    for (const value of Object.values(requestBindings)) {
      if (
        typeof value === "object" &&
        value !== null &&
        typeof (value as Record<string, unknown>).workerId === "string"
      ) {
        desiredWorkerIds.add(
          (value as Record<string, unknown>).workerId as string,
        );
      }
    }
  }
  const desiredWorkers = new Map<string, Record<string, unknown>>();
  if (desiredWorkerIds.size > 0) {
    const workerPlaceholders = [...desiredWorkerIds]
      .map((_, index) => `?${index + 1}`)
      .join(", ");
    const workerRows = await env.CONCLAVE_DB.prepare(
      `SELECT worker_id AS workerId, worker_type_id AS workerTypeId,
              engine_version AS engineVersion,
              profile_definition_id AS profileDefinitionId,
              profile_release_version AS profileReleaseVersion,
              provider_tool_name AS providerToolName,
              provider_tool_version AS providerToolVersion
         FROM workspace_worker_inventory WHERE worker_id IN (${workerPlaceholders})`,
    )
      .bind(...desiredWorkerIds)
      .all<Record<string, unknown>>();
    for (const worker of workerRows.results ?? []) {
      desiredWorkers.set(String(worker.workerId), worker);
    }
  }
  const taskRows = await env.CONCLAVE_DB.prepare(
    `SELECT wt.work_request_id AS workRequestId, wt.step_kind AS kind,
            wt.status, wt.output_json AS outputJson, wt.error,
            COALESCE(wt.started_at, wt.created_at) AS startedAt,
            COALESCE(wt.finished_at, wt.updated_at) AS updatedAt,
            wa.error_json AS assignmentErrorJson,
            wa.workspace_worker_id AS workerId,
            wa.worker_id AS logicalWorkerTypeId,
            wa.model AS assignedModel,
            wa.engine_version AS engineVersion,
            wa.permission_snapshot_json AS permissionSnapshotJson,
            wi.worker_type_id AS configuredWorkerTypeId,
            wi.provider_tool_name AS configuredProviderToolName,
            wi.provider_tool_version AS configuredProviderToolVersion
       FROM workflow_tasks wt
       JOIN work_requests wr ON wr.id = wt.work_request_id
       LEFT JOIN worker_assignments wa ON wa.id = (
         SELECT wa2.id FROM worker_assignments wa2
          WHERE wa2.task_id = wt.id
          ORDER BY wa2.created_at DESC, wa2.id DESC LIMIT 1
       )
       LEFT JOIN workspace_worker_inventory wi ON wi.worker_id = COALESCE(
         wa.workspace_worker_id,
         json_extract(wr.snapshot_json, '$.resolvedBindings.' ||
           CASE WHEN wr.workflow_id = 'direct' THEN 'direct' ELSE wt.step_kind END || '.workerId')
       )
      WHERE wt.work_request_id IN (${placeholders})
      ORDER BY wt.created_at, wt.id`,
  )
    .bind(...ids)
    .all<Record<string, unknown>>();
  const tasksByRequest = new Map<string, Record<string, unknown>[]>();
  for (const task of taskRows.results ?? []) {
    const key = String(task.workRequestId);
    const values = tasksByRequest.get(key) ?? [];
    values.push(task);
    tasksByRequest.set(key, values);
  }
  const workRequests = requests.map((row) => {
    const id = String(row.id);
    const input = parseJson<Record<string, unknown>>(String(row.inputJson), {});
    const workflow = parseJson<Record<string, unknown>>(
      String(row.workflowSnapshotJson),
      {},
    );
    const snapshot = parseJson<Record<string, unknown>>(
      typeof row.snapshotJson === "string" ? row.snapshotJson : null,
      {},
    );
    const bindings =
      typeof snapshot.resolvedBindings === "object" &&
      snapshot.resolvedBindings !== null
        ? (snapshot.resolvedBindings as Record<string, unknown>)
        : {};
    const persistedTasks = tasksByRequest.get(id) ?? [];
    const taskByKind = new Map(
      persistedTasks.map((task) => [String(task.kind), task]),
    );
    const workflowSteps = Array.isArray(workflow.steps) ? workflow.steps : [];
    const steps = workflowSteps.flatMap((value) => {
      if (!value || typeof value !== "object") return [];
      const definition = value as Record<string, unknown>;
      const kind = String(definition.kind ?? "implement");
      const task = taskByKind.get(kind);
      const bindingId = row.workflowId === "direct" ? "direct" : kind;
      const bindingValue = bindings[bindingId];
      const binding =
        typeof bindingValue === "object" && bindingValue !== null
          ? (bindingValue as Record<string, unknown>)
          : {};
      const desiredWorker =
        typeof binding.workerId === "string"
          ? desiredWorkers.get(binding.workerId)
          : undefined;
      const output =
        typeof task?.outputJson === "string"
          ? parseJson<Record<string, unknown>>(task.outputJson, {})
          : {};
      const permissionSnapshot = parseJson<Record<string, unknown>>(
        typeof task?.permissionSnapshotJson === "string"
          ? task.permissionSnapshotJson
          : null,
        {},
      );
      const hasAssignment = typeof task?.workerId === "string";
      const testSummary =
        kind === "test" && typeof output.text === "string"
          ? summarizeTestCounts(output.text)
          : null;
      const assignmentError = parseJson<Record<string, unknown>>(
        typeof task?.assignmentErrorJson === "string"
          ? task.assignmentErrorJson
          : null,
        {},
      );
      const assignmentErrorValue = assignmentError.error;
      const assignmentErrorDetail =
        typeof assignmentErrorValue === "object" &&
        assignmentErrorValue !== null
          ? (assignmentErrorValue as Record<string, unknown>)
          : {};
      const stableErrorCode =
        typeof assignmentErrorDetail.code === "string"
          ? canonicalExecutionErrorCode(assignmentErrorDetail.code)
          : typeof task?.error === "string"
            ? canonicalExecutionErrorCode(task.error)
            : null;
      const created = task?.startedAt
        ? Date.parse(String(task.startedAt))
        : NaN;
      const updated = task?.updatedAt
        ? Date.parse(String(task.updatedAt))
        : Date.now();
      const finished = ["completed", "failed", "cancelled"].includes(
        String(task?.status),
      );
      return [
        {
          kind,
          status: String(
            task?.status ?? (row.status === "queued" ? "queued" : "waiting"),
          ),
          workerId: task?.workerId ?? binding.workerId ?? null,
          workerTypeId: hasAssignment
            ? (task?.logicalWorkerTypeId ?? null)
            : (task?.configuredWorkerTypeId ??
              desiredWorker?.workerTypeId ??
              null),
          engineVersion: hasAssignment
            ? typeof permissionSnapshot.profileDefinitionId === "string"
              ? (task?.engineVersion ?? null)
              : null
            : (desiredWorker?.engineVersion ?? null),
          profileDefinitionId: hasAssignment
            ? typeof permissionSnapshot.profileDefinitionId === "string"
              ? permissionSnapshot.profileDefinitionId
              : null
            : (desiredWorker?.profileDefinitionId ?? null),
          profileReleaseVersion: hasAssignment
            ? Number.isSafeInteger(permissionSnapshot.profileReleaseVersion)
              ? permissionSnapshot.profileReleaseVersion
              : null
            : (desiredWorker?.profileReleaseVersion ?? null),
          model: hasAssignment
            ? (task?.assignedModel ?? null)
            : typeof binding.model === "string"
              ? binding.model
              : null,
          providerToolName:
            (typeof permissionSnapshot.providerToolName === "string"
              ? permissionSnapshot.providerToolName
              : null) ??
            (hasAssignment ? null : task?.configuredProviderToolName) ??
            desiredWorker?.providerToolName ??
            null,
          providerToolVersion:
            (typeof permissionSnapshot.providerToolVersion === "string"
              ? permissionSnapshot.providerToolVersion
              : null) ??
            (hasAssignment ? null : task?.configuredProviderToolVersion) ??
            desiredWorker?.providerToolVersion ??
            null,
          startedAt: task?.startedAt ?? null,
          updatedAt: task?.updatedAt ?? null,
          elapsedMs: Number.isFinite(created)
            ? Math.max(0, (finished ? updated : Date.now()) - created)
            : null,
          finalText: typeof output.text === "string" ? output.text : null,
          ...(testSummary ? { testSummary } : {}),
          errorCode: stableErrorCode,
          errorMessage: stableErrorCode
            ? executionErrorMessage(stableErrorCode)
            : null,
          error: typeof task?.error === "string" ? task.error : null,
        },
      ];
    });
    const terminalStep = steps.at(-1);
    const finalText =
      row.status === "completed" && terminalStep?.status === "completed"
        ? terminalStep.finalText
        : null;
    const stepError = [...steps]
      .reverse()
      .map((step) => step.error)
      .find(
        (error): error is string =>
          typeof error === "string" && error.length > 0,
      );
    const errorCode = stepError ? canonicalExecutionErrorCode(stepError) : null;
    return {
      id,
      requestedByName: String(row.requestedByName ?? "Team member"),
      prompt: String(input.originalRequest ?? input.request ?? ""),
      workflowId: String(row.workflowId),
      workflowVersion: Number(row.workflowVersion),
      status: String(row.status),
      createdAt: String(row.createdAt),
      updatedAt: String(row.updatedAt),
      steps: steps.map(({ finalText: _text, error: _error, ...step }) => step),
      ...(finalText ? { finalText } : {}),
      ...(errorCode
        ? {
            errorCode,
            error:
              "A Step could not be completed. Open Run details for the safe error code.",
          }
        : {}),
    };
  });
  const last = requests.at(-1)!;
  return json({
    workRequests,
    nextCursor:
      requests.length === limit
        ? { createdAt: String(last.createdAt), id: String(last.id) }
        : null,
  });
}

export async function handleCancelWorkRequest(
  request: Request,
  env: SecurityEnv,
  workRequestId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT workstream_id AS workstreamId, mode, status, cancel_requested_at AS cancelRequestedAt FROM work_requests WHERE id = ?1",
  )
    .bind(workRequestId)
    .first<{
      workstreamId: string;
      mode: string;
      status: string;
      cancelRequestedAt: string | null;
    }>();
  if (!row) throw new HttpError(404, "Work Request not found");
  await authorizeWorkstreamAccess(
    request,
    env,
    row.workstreamId,
    "execute",
    accessContext,
  );
  if (row.status === "cancelled")
    return json({ workRequestId, status: "cancelled" });
  if (row.status === "failed") {
    const now = new Date().toISOString();
    await env.CONCLAVE_DB.batch([
      env.CONCLAVE_DB.prepare(
        "UPDATE work_requests SET status = 'cancelled', updated_at = ?1 WHERE id = ?2 AND status = 'failed'",
      ).bind(now, workRequestId),
      env.CONCLAVE_DB.prepare(
        `UPDATE runs SET status = 'cancelled', finished_at = ?1, updated_at = ?1
          WHERE id = (SELECT id FROM runs WHERE work_request_id = ?2 AND status = 'failed'
                     ORDER BY created_at DESC, id DESC LIMIT 1)`,
      ).bind(now, workRequestId),
      env.CONCLAVE_DB.prepare(
        `UPDATE workflow_tasks SET status = 'cancelled', finished_at = ?1, updated_at = ?1
          WHERE work_request_id = ?2 AND status IN ('queued', 'waiting')`,
      ).bind(now, workRequestId),
    ]);
    return json({ workRequestId, status: "cancelled" });
  }
  if (row.status === "queued" && row.mode === "stateful") {
    if (!env.CONCLAVE_WORKSTREAM_COORDINATOR)
      throw new HttpError(503, "Workstream execution coordinator unavailable");
    const coordinator = env.CONCLAVE_WORKSTREAM_COORDINATOR.getByName(
      row.workstreamId,
    );
    return coordinator.fetch(
      new Request("https://workstream-coordinator/cancel", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-workstream-id": row.workstreamId,
        },
        body: JSON.stringify({ workRequestId }),
      }),
    );
  }
  if (row.status === "queued") {
    const now = new Date().toISOString();
    await env.CONCLAVE_DB.batch([
      env.CONCLAVE_DB.prepare(
        "UPDATE work_requests SET status = 'cancelled', updated_at = ?1 WHERE id = ?2 AND status = 'queued'",
      ).bind(now, workRequestId),
      env.CONCLAVE_DB.prepare(
        "UPDATE runs SET status = 'cancelled', finished_at = ?1, updated_at = ?1 WHERE work_request_id = ?2 AND status = 'created'",
      ).bind(now, workRequestId),
      env.CONCLAVE_DB.prepare(
        "UPDATE workflow_tasks SET status = 'cancelled', finished_at = ?1, updated_at = ?1 WHERE work_request_id = ?2 AND status IN ('queued', 'waiting')",
      ).bind(now, workRequestId),
    ]);
    return json({ workRequestId, status: "cancelled" });
  }
  if (row.status !== "running")
    throw new HttpError(409, "This Work Request cannot be cancelled");

  const requestedAt = row.cancelRequestedAt ?? new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    "UPDATE work_requests SET cancel_requested_at = COALESCE(cancel_requested_at, ?1), updated_at = ?1 WHERE id = ?2 AND status = 'running'",
  )
    .bind(requestedAt, workRequestId)
    .run();

  const active = await env.CONCLAVE_DB.prepare(
    `SELECT wa.id AS assignmentId, wa.execution_workspace_id AS workspaceId,
            wa.status AS assignmentStatus
       FROM workflow_tasks wt
       JOIN worker_assignments wa ON wa.task_id = wt.id
      WHERE wt.work_request_id = ?1 AND wt.status = 'running'
        AND wa.status IN ('created', 'dispatched', 'acknowledged', 'running')
      ORDER BY wa.created_at DESC LIMIT 1`,
  )
    .bind(workRequestId)
    .first<{
      assignmentId: string;
      workspaceId: string;
      assignmentStatus: string;
    }>();
  if (active) {
    const cancellation = await cancelTaskAssignment(
      env as unknown as AssignmentDispatcherEnv,
      active.workspaceId,
      active.assignmentId,
      "Work Request cancelled from Work chat",
    );
    if (!cancellation.cancelled)
      throw new HttpError(
        503,
        "Workspace did not confirm that the Worker process tree stopped. The Run remains active; retry cancellation.",
      );
  }

  const now = new Date().toISOString();
  await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      "UPDATE work_requests SET status = 'cancelled', updated_at = ?1 WHERE id = ?2 AND status = 'running'",
    ).bind(now, workRequestId),
    env.CONCLAVE_DB.prepare(
      "UPDATE runs SET status = 'cancelled', finished_at = ?1, updated_at = ?1 WHERE work_request_id = ?2 AND status IN ('created', 'running')",
    ).bind(now, workRequestId),
    env.CONCLAVE_DB.prepare(
      "UPDATE workflow_tasks SET status = 'cancelled', finished_at = ?1, updated_at = ?1 WHERE work_request_id = ?2 AND status IN ('queued', 'waiting')",
    ).bind(now, workRequestId),
  ]);
  if (!active) {
    await env.CONCLAVE_DB.prepare(
      "UPDATE workflow_tasks SET status = 'cancelled', finished_at = ?1, updated_at = ?1 WHERE work_request_id = ?2 AND status = 'running'",
    )
      .bind(now, workRequestId)
      .run();
    const run = await env.CONCLAVE_DB.prepare(
      "SELECT id FROM runs WHERE work_request_id = ?1 ORDER BY created_at DESC LIMIT 1",
    )
      .bind(workRequestId)
      .first<{ id: string }>();
    if (run && env.CONCLAVE_RUN_WORKFLOW) {
      const instanceId = await resolveWorkflowInstanceId(env, run.id);
      const instance = await env.CONCLAVE_RUN_WORKFLOW.get(instanceId);
      await instance.terminate();
    }
  }
  return json({ workRequestId, status: "cancelled" });
}

export async function handleStudioSnapshot(
  env: Env,
  request: Request,
  projectId: string | null,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const securityEnv = env as SecurityEnv;
  const context = projectId
    ? await authorizeRequest(
        request,
        securityEnv,
        "projects:read",
        projectId,
        accessContext,
      )
    : await securityContext(request, securityEnv, accessContext);
  {
    // The snapshot is derived from current Project membership and Workstream
    // policy; Workspace execution access remains grant-scoped.
    const rows = await env.CONCLAVE_DB.prepare(
      `SELECT p.id, p.name, p.description,
              p.settings_json AS settingsJson,
              p.updated_at AS lastActivity
       FROM projects p
       JOIN project_memberships pm ON pm.project_id = p.id
       WHERE pm.user_id = ?1
         AND COALESCE(json_extract(p.settings_json, '$.archived'), 0) = 0
       ORDER BY p.updated_at DESC`,
    )
      .bind(context.userId)
      .all<{
        id: string;
        name: string;
        description: string | null;
        settingsJson: string | null;
        lastActivity: string;
      }>();
    const workstreamRows = await env.CONCLAVE_DB.prepare(
      `SELECT ws.id, ws.project_id AS projectId, ws.name, ws.status,
              ws.access_policy_json AS accessPolicyJson,
              ws.lead_user_id AS leadUserId,
              pm.id AS membershipId,
              pm.role AS memberRole,
              ws.created_at AS createdAt, ws.updated_at AS updatedAt
       FROM workstreams ws
       JOIN project_memberships pm ON pm.project_id = ws.project_id
       WHERE pm.user_id = ?1
       ORDER BY ws.created_at ASC`,
    )
      .bind(context.userId)
      .all<Record<string, unknown>>();
    const workstreamsByProject = new Map<string, Record<string, unknown>[]>();
    for (const row of workstreamRows.results ?? []) {
      const projectWorkstreams =
        workstreamsByProject.get(String(row.projectId)) ?? [];
      projectWorkstreams.push({
        ...workstreamMetadata(row),
        canConfigureWork:
          row.memberRole === "owner" ||
          (row.memberRole === "collaborator" &&
            String(row.leadUserId) === context.userId),
        canExecuteWork: canExecuteWorkstream(
          context.userId,
          {
            id: String(row.membershipId ?? ""),
            projectId: String(row.projectId),
            userId: context.userId,
            role: String(row.memberRole) as ProjectMembership["role"],
            createdAt: String(row.createdAt ?? ""),
            updatedAt: String(row.updatedAt ?? ""),
          },
          {
            id: String(row.id),
            projectId: String(row.projectId),
            name: String(row.name),
            status: String(row.status) as Workstream["status"],
            accessPolicy: {
              ...DEFAULT_WORKSTREAM_ACCESS_POLICY,
              ...parseJson(row.accessPolicyJson, {}),
            },
            lead: {
              userId: String(row.leadUserId),
              assignedAt: String(row.createdAt),
              assignedByUserId: String(row.leadUserId),
            },
            createdAt: String(row.createdAt),
            updatedAt: String(row.updatedAt),
          },
        ),
      });
      workstreamsByProject.set(String(row.projectId), projectWorkstreams);
    }
    return json({
      workspaceId: null,
      viewer: {
        id: context.userId,
        displayName: context.user.displayName,
        email: context.user.email,
      },
      activeRunId: null,
      run: null,
      projects: (rows.results ?? []).map((project) => {
        const settings = parseJson(project.settingsJson);
        const rawWorkstreams =
          workstreamsByProject.get(String(project.id)) ?? [];
        return {
          id: project.id,
          name: project.name,
          description: project.description,
          instructions:
            typeof settings.instructions === "string"
              ? settings.instructions
              : "",
          settings,
          branch: "",
          workstreams: sortWorkstreams(
            rawWorkstreams,
            settings.workstreamOrder,
          ),
        };
      }),
      tasks: [],
      findings: [],
      events: [],
      artifacts: [],
      modelCalls: [],
    });
  }

}

/**
 * Project-scoped read model used by the web App. Keep this response limited to
 * the active project so a large Workspace does not turn every refresh into a
 * full application snapshot.
 */
export async function handleProjectReadModel(
  env: Env,
  request: Request,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const securityEnv = env as SecurityEnv;
  const context = await authorizeRequest(
    request,
    securityEnv,
    "projects:read",
    projectId,
    accessContext,
  );
  const projectRow = await env.CONCLAVE_DB.prepare(
    `SELECT p.id, p.name,
            p.description, p.settings_json AS settings,
            p.created_at AS createdAt, p.updated_at AS updatedAt
     FROM projects p
     WHERE p.id = ?1`,
  )
    .bind(projectId)
    .first<{
      id: string;
      name: string;
      description: string | null;
      settings: string;
      createdAt: string;
      updatedAt: string;
    }>();
  if (!projectRow) throw new HttpError(404, "Project not found");

  const project = {
    ...projectRow,
    settings: parseJson(projectRow.settings),
  };

  const latestRun = await env.CONCLAVE_DB.prepare(
    `SELECT r.id, r.status, g.objective, r.created_at AS createdAt,
            r.started_at AS startedAt, r.finished_at AS finishedAt
     FROM runs r JOIN goals g ON g.id = r.goal_id
     WHERE r.project_id = ?1
     ORDER BY r.created_at DESC LIMIT 1`,
  )
    .bind(projectId)
    .first<Record<string, unknown>>();
  return json({
    workspaceId: null,
    project,
    run: latestRun ?? null,
    activeRunId:
      latestRun &&
      ["created", "running", "paused"].includes(String(latestRun.status))
        ? latestRun.id
        : null,
    tasks: [],
    findings: [],
    events: [],
    artifacts: [],
  });
}

export async function handleRunCommand(
  request: Request,
  env: Env,
  runId: string,
  command:
    | "pause"
    | "resume"
    | "restart"
    | "cancel"
    | "event"
    | "ci-evidence"
    | "forge-terminal",
  accessContext?: ExecutionContext,
): Promise<Response> {
  const securityEnv = env as SecurityEnv;
  let controlContext: SecurityContext | undefined;
  if (command === "ci-evidence") requireCiAuthentication(request, securityEnv);
  if (command === "forge-terminal") {
    requireForgeCallbackAuthentication(request, securityEnv);
  } else {
    const projectId = testAuthenticationEnabled(securityEnv)
      ? undefined
      : await runProjectId(securityEnv, runId);
    controlContext = await authorizeRequest(
      request,
      securityEnv,
      "runs:control",
      projectId,
      accessContext,
    );
  }
  const workflowInstanceId = await resolveWorkflowInstanceId(env, runId);
  const instance = await env.CONCLAVE_RUN_WORKFLOW.get(workflowInstanceId);
  let claimedEvidenceId: string | undefined;
  if (command === "ci-evidence") {
    const body = (await request.clone().json()) as Record<string, unknown>;
    claimedEvidenceId = await validateAndClaimCiEvidence(
      env,
      runId,
      body.payload ?? body,
    );
  }
  if (command === "pause") await instance.pause();
  if (command === "resume") await instance.resume();
  if (command === "restart") await instance.restart();
  if (command === "cancel") await instance.terminate();
  if (command === "pause" || command === "resume" || command === "cancel") {
    const status =
      command === "pause"
        ? "paused"
        : command === "cancel"
          ? "cancelled"
          : "running";
    await env.CONCLAVE_DB.prepare(
      "UPDATE runs SET status = ?1, finished_at = CASE WHEN ?1 = 'cancelled' THEN ?2 ELSE finished_at END, updated_at = ?2 WHERE id = ?3",
    )
      .bind(status, new Date().toISOString(), runId)
      .run();
  }
  if (controlContext && command !== "ci-evidence") {
    await recordAudit(
      env as SecurityEnv,
      controlContext,
      `run.${command}`,
      "run",
      runId,
    );
  }
  if (
    command === "event" ||
    command === "ci-evidence" ||
    command === "forge-terminal"
  ) {
    const body = (await request.json()) as Record<string, unknown>;
    if (command === "ci-evidence") {
      await instance.sendEvent({
        type: "ci-evidence",
        payload: body.payload ?? body,
      });
      await env.CONCLAVE_DB.prepare(
        "UPDATE ci_evidence SET status = 'consumed', consumed_at = ?1 WHERE evidence_id = ?2 AND status = 'claimed'",
      )
        .bind(new Date().toISOString(), claimedEvidenceId)
        .run();
    } else if (command === "forge-terminal") {
      await instance.sendEvent({
        type: "forge-terminal",
        payload: body.payload ?? body,
      });
    } else {
      const type = requiredString(body.type, "type");
      if (type !== "run-control" && type !== "run-approval") {
        throw new Error("Unsupported workflow event type");
      }
      await instance.sendEvent({ type, payload: body.payload });
    }
  }
  return json({
    id: runId,
    workflowInstanceId,
    status: (await instance.status()).status,
  });
}
