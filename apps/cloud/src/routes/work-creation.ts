import {
  parseWorkflowExecutionSelection,
  resolveWorkflowExecutionBindings,
} from "./workflow-execution-configuration.js";
import { requireWorkflowPermission } from "./space-permissions.js";
import { initialConversationTaskStatements } from "./conversation-workflow-step-runs.js";
import { MutationIdempotency } from "./mutation-idempotency.js";
import { resolveWorkflowStepExecutionConfig } from "./workflow-step-execution-config.js";
import {
  conversationId,
  conversationSubmissionStatements,
} from "./conversations.js";
import {
  validateWorkRequest,
  validateBuiltinWorkflowDefinition,
  BUILTIN_WORKFLOWS,
  conversationWorkflowForExecution,
  type WorkRequest,
  type WorkRequestSnapshot,
  type ThreadExecutionPolicy,
  type BuiltinWorkflowDefinition,
  type WorkflowId,
} from "@conclave/core";

import { createEventPublisher } from "../event-publisher.js";
import {
  HttpError,
  authorizeThreadAccess,
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
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { context, spaceId } = await authorizeThreadAccess(
    request,
    env,
    threadId,
    "execute",
    accessContext,
  );
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT wc.config_json AS configJson FROM threads ws
       LEFT JOIN thread_work_configs wc ON wc.thread_id = ws.id WHERE ws.id = ?1`,
  )
    .bind(threadId)
    .first<{ configJson: string | null }>();
  const config = parseJson<Record<string, unknown>>(row?.configJson, {
    defaultWorkflowId: "full_cycle",
    bindings: {},
  });
  const body = (await request.json()) as Record<string, unknown>;
  const executionSelection = parseWorkflowExecutionSelection(
    body.executionSelection,
  );
  const workflowId = requiredString(
    body.workflowId ?? config.defaultWorkflowId,
    "workflowId",
  ) as WorkflowId;
  const workflow = BUILTIN_WORKFLOWS[workflowId];
  if (!workflow) throw new HttpError(400, "Unsupported workflowId");
  await requireWorkflowPermission(env, context.userId, spaceId, workflowId);
  if (body.attachments !== undefined && !Array.isArray(body.attachments)) {
    throw new HttpError(400, "attachments must be an array");
  }
  const attachments = Array.isArray(body.attachments) ? body.attachments : [];
  if (attachments.length > 10)
    throw new HttpError(400, "At most 10 attachments are allowed");
  const { issues } = await validateWorkflowWorkerEligibility(
    env,
    spaceId,
    threadId,
    workflow,
    await resolveWorkflowExecutionBindings(
      env,
      context.userId,
      spaceId,
      threadId,
      workflow,
      {},
      attachments,
      executionSelection,
    ),
    attachments,
  );
  if (
    !env.CONCLAVE_THREAD_COORDINATOR &&
    workflow.steps.some((step) => step.executionMode === "stateful_thread")
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
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { context, spaceId } = await authorizeThreadAccess(
    request,
    env,
    threadId,
    "execute",
    accessContext,
  );
  const body = (await request.json()) as Record<string, unknown>;
  const executionSelection = parseWorkflowExecutionSelection(
    body.executionSelection,
  );
  const receipt = await MutationIdempotency.from(
    request,
    env.CONCLAVE_DB,
    context.userId,
    `thread:${threadId}:create-work-request`,
    body,
  );
  const replay = await receipt?.replay();
  const requestedMode =
    body.mode === "stateful"
      ? "stateful"
      : body.mode === "stateless"
        ? "stateless"
        : null;
  const workConfigRow = await env.CONCLAVE_DB.prepare(
    `SELECT wc.config_json AS configJson, p.settings_json AS settingsJson
     FROM threads ws
     JOIN spaces p ON p.id = ws.space_id
     LEFT JOIN thread_work_configs wc ON wc.thread_id = ws.id
     WHERE ws.id = ?1`,
  )
    .bind(threadId)
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
  await requireWorkflowPermission(env, context.userId, spaceId, workflowId);
  if (replay) return resumeSubmission(env, replay);
  // Mutation coordination follows the authoritative Steps, independently of
  // durable provider conversation/session state.
  const mode = canonicalWorkflow.steps.some(
    (step) => step.executionMode === "stateful_thread",
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
  const stepAdditionalInstructions: WorkRequestSnapshot["stepAdditionalInstructions"] =
    {};
  const promptProfileVersions: WorkRequestSnapshot["promptProfileVersions"] =
    {};
  const instructions: Record<string, { additionalInstructions?: string }> = {};
  for (const step of workflowSnapshot.steps) {
    const id = workflowId === "direct" ? "direct" : step.kind;
    const binding = configuredBindings[id] as
      Record<string, unknown> | undefined;
    if (typeof binding?.additionalInstructions === "string") {
      instructions[id] = {
        additionalInstructions: binding.additionalInstructions,
      };
      stepAdditionalInstructions[step.kind] = binding.additionalInstructions;
    }
    promptProfileVersions[step.kind] = step.promptProfileVersion;
  }
  const resolvedBindings = await resolveWorkflowExecutionBindings(
    env,
    context.userId,
    spaceId,
    threadId,
    workflowSnapshot,
    instructions,
    normalizedAttachments,
    executionSelection,
  );
  const eligibility = await validateWorkflowWorkerEligibility(
    env,
    spaceId,
    threadId,
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
  if (!env.CONCLAVE_THREAD_COORDINATOR && mode === "stateful") {
    throw new HttpError(503, "Thread runtime coordination is unavailable");
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
  const spaceSettings = parseJson<Record<string, unknown>>(
    workConfigRow?.settingsJson,
    {},
  );
  const spaceInstructions =
    typeof spaceSettings.instructions === "string"
      ? spaceSettings.instructions
      : "";
  const threadInstructions =
    typeof workConfig.threadInstructions === "string"
      ? workConfig.threadInstructions
      : "";
  const manualWorkflow = conversationWorkflowForExecution(
    workflowId,
    workflowVersion,
  );
  const manualBindingId =
    manualWorkflow?.execution.workflowId === "direct" ? "direct" : "chat";
  const manualBinding = resolvedBindings[manualBindingId];
  const executionConfig = manualWorkflow
    ? resolveWorkflowStepExecutionConfig(
        workflowSnapshot,
        manualBinding?.workerId ?? "",
        eligibility.workerProfiles?.[manualBindingId],
        manualBinding?.model ?? null,
        manualBinding?.reasoningEffort ?? null,
      )
    : undefined;
  const stepExecutionConfigs: Record<
    string,
    import("@conclave/core").TurnExecutionConfig
  > = {};
  for (const step of workflowSnapshot.steps) {
    const bindingId = workflowId === "direct" ? "direct" : step.kind;
    const binding = resolvedBindings[bindingId]!;
    stepExecutionConfigs[step.kind] = resolveWorkflowStepExecutionConfig(
      workflowSnapshot,
      binding.workerId ?? "",
      eligibility.workerProfiles[bindingId],
      binding.model ?? null,
      binding.reasoningEffort ?? null,
    );
  }
  const snapshot: WorkRequestSnapshot = {
    ...(executionConfig ? { turnExecutionConfig: executionConfig } : {}),
    schemaVersion: 1,
    stepExecutionConfigs,
    originalRequest,
    attachmentReferences,
    workflowId,
    workflowVersion,
    workflowSnapshot,
    resolvedBindings,
    spaceInstructions,
    threadInstructions,
    stepAdditionalInstructions,
    promptProfileVersions,
  };
  const policyRow = await env.CONCLAVE_DB.prepare(
    "SELECT mode, primary_workspace_id AS primaryWorkspaceId FROM thread_execution_policies WHERE thread_id = ?1",
  )
    .bind(threadId)
    .first<ThreadExecutionPolicy>();
  const policy: ThreadExecutionPolicy =
    canonicalWorkflow.steps.length === 1
      ? {
          mode,
          primaryWorkspaceId:
            typeof body.primaryWorkspaceId === "string"
              ? body.primaryWorkspaceId
              : null,
        }
      : (policyRow ?? {
          mode,
          primaryWorkspaceId:
            typeof body.primaryWorkspaceId === "string"
              ? body.primaryWorkspaceId
              : null,
        });
  const now = new Date().toISOString();
  const conversationWorkflow = conversationWorkflowForExecution(
    workflowId,
    workflowVersion,
  );
  const selectedConversationId = conversationWorkflow
    ? conversationId(threadId, conversationWorkflow.id)
    : undefined;
  if (
    body.conversationId !== undefined &&
    body.conversationId !== selectedConversationId
  ) {
    throw new HttpError(
      400,
      "Conversation does not match this Thread and Workflow",
    );
  }
  const workRequest: WorkRequest = {
    id: `work-request-${crypto.randomUUID()}`,
    ...(selectedConversationId
      ? { conversationId: selectedConversationId }
      : {}),
    ...(executionConfig ? { executionConfig } : {}),
    threadId,
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
  const responseBody = {
    workRequest,
    run: { id: runId, spaceId, threadId, status: "created" },
  };
  const write = (receipts: D1PreparedStatement[]) =>
    env.CONCLAVE_DB.batch([
      ...receipts,
      env.CONCLAVE_DB.prepare(
        `INSERT INTO work_requests
       (id, thread_id, requested_by_user_id, mode, workflow_id, workflow_version, workflow_snapshot_json, snapshot_json, status, primary_workspace_id, input_json, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'queued', ?9, ?10, ?11, ?11)`,
      ).bind(
        workRequest.id,
        threadId,
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
      ...(conversationWorkflow
        ? conversationSubmissionStatements(
            env.CONCLAVE_DB,
            threadId,
            conversationWorkflow,
            workRequest.id,
            now,
          )
        : []),
      ...(conversationWorkflow
        ? initialConversationTaskStatements(
            env.CONCLAVE_DB,
            workflowSnapshot,
            workRequest.id,
            now,
          )
        : []),
      env.CONCLAVE_DB.prepare(
        `INSERT INTO runs
       (id, space_id, thread_id, work_request_id, status, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, 'created', ?5, ?5)`,
      ).bind(runId, spaceId, threadId, workRequest.id, now),
      env.CONCLAVE_DB.prepare(
        `INSERT INTO space_audit_log
       (id, space_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
       VALUES (?1, ?2, 'user', ?3, 'thread.work_requested', 'work_request', ?4, ?5, ?6)`,
      ).bind(
        `pa-${crypto.randomUUID()}`,
        spaceId,
        context.userId,
        workRequest.id,
        JSON.stringify({ threadId, runId, workflowId, workflowVersion }),
        now,
      ),
    ]);
  const concurrentReplay = receipt
    ? await receipt.commit(responseBody, 202, write)
    : (await write([]), null);
  if (concurrentReplay) return resumeSubmission(env, concurrentReplay);
  try {
    await createEventPublisher(env).publish({
      type: "work_request.created",
      workspaceId: workRequest.primaryWorkspaceId!,
      spaceId,
      runId,
      idempotencyKey: `work-request:${workRequest.id}:created`,
      payload: {
        entityId: workRequest.id,
        workRequestId: workRequest.id,
        threadId,
        status: "queued",
        ...(request.headers.get("Idempotency-Key")
          ? { submissionId: request.headers.get("Idempotency-Key")! }
          : {}),
      },
    });
  } catch (error) {
    console.error("Failed to publish work_request.created", error);
  }
  return resumeSubmission(env, json(responseBody, { status: 202 }), false);
}

/** Resume only this committed submission, using its existing runtime identities. */
async function resumeSubmission(
  env: SecurityEnv,
  response: Response,
  replay = true,
): Promise<Response> {
  const { workRequest, run } = (await response.clone().json()) as {
    workRequest: WorkRequest;
    run: { id: string; spaceId: string; threadId: string };
  };
  if (replay) {
    const row = await env.CONCLAVE_DB.prepare(
      "SELECT status FROM work_requests WHERE id = ?1",
    )
      .bind(workRequest.id)
      .first<{ status: string }>();
    if (!row || ["completed", "failed", "cancelled"].includes(row.status))
      return response;
  }
  if (workRequest.mode === "stateful" && env.CONCLAVE_THREAD_COORDINATOR) {
    const coordinator = env.CONCLAVE_THREAD_COORDINATOR.getByName(
      workRequest.threadId,
    );
    const result = await coordinator.fetch(
      new Request("https://thread-coordinator/enqueue", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-thread-id": workRequest.threadId,
        },
        body: JSON.stringify({ workRequestId: workRequest.id }),
      }),
    );
    if (!result.ok)
      throw new HttpError(503, "Thread execution coordinator unavailable");
  }
  await createOrGetRun(env, {
    runId: run.id,
    goalId: workRequest.id,
    idempotencyKey: workRequest.id,
    organizationId: workRequest.primaryWorkspaceId!,
    workRequestId: workRequest.id,
    threadId: workRequest.threadId,
    spaceId: run.spaceId,
    builtinWorkflow: workRequest.workflowSnapshot,
    input: workRequest.input,
  });
  return response;
}
