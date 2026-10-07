import {
  ContextEngine,
  emptyContextState,
  projectContextState,
  type ContextHistoryFact,
  type ContextWorkflowState,
  type WorkflowExecutionContext,
} from "@conclave/core";
/** Conclave canonical history only. This contains no provider-native state. */
export interface ConversationBootstrap {
  readonly schemaVersion: 1;
  readonly conversationId: string;
  readonly contextRevision: number;
  readonly throughSequence: number;
  readonly text: string;
  readonly turnRevision: number;
}

export async function loadConversationBootstrap(
  db: D1Database,
  conversationId: string,
  workRequestId: string,
  contextRevision: number,
  mode: "bootstrap" | "stateless" = "bootstrap",
  activeStepId?: string,
): Promise<ConversationBootstrap> {
  // Freeze a high-water mark at dispatch, including late results from older
  // requests while excluding the current and future accepted requests.
  const boundary = await db
    .prepare(
      `SELECT conversation_revision AS revision FROM conversation_work_requests
    WHERE conversation_id = ?1 AND work_request_id = ?2`,
    )
    .bind(conversationId, workRequestId)
    .first<{ revision: number }>();
  if (!boundary)
    throw new Error("Canonical Conversation request boundary is missing");
  if (contextRevision !== boundary.revision - 1)
    throw new Error("Canonical context revision does not match this turn");
  const highWater = await db
    .prepare(
      `SELECT COALESCE(MAX(sequence),0) AS sequence FROM conversation_history_entries WHERE conversation_id = ?1`,
    )
    .bind(conversationId)
    .first<{ sequence: number }>();
  const throughSequence = highWater?.sequence ?? 0;
  const bounds = await db
    .prepare(
      `SELECT COUNT(*) AS count,
    COALESCE(SUM(length(CAST(COALESCE(text,'') AS BLOB)) + length(CAST(metadata_json AS BLOB))),0) AS bytes
    FROM conversation_history_entries h WHERE conversation_id = ?1 AND sequence <= ?2
      AND (h.work_request_id IS NULL OR EXISTS (SELECT 1 FROM conversation_work_requests cr
        WHERE cr.conversation_id = h.conversation_id AND cr.work_request_id = h.work_request_id AND cr.conversation_revision <= ?3))`,
    )
    .bind(conversationId, throughSequence, contextRevision)
    .first<{ count: number; bytes: number }>();
  if (!bounds || bounds.count > 1000 || bounds.bytes > 256 * 1024) {
    throw new Error("Conversation bootstrap exceeds the history or byte limit");
  }
  const result = await db
    .prepare(
      `SELECT sequence, kind, event_type AS eventType, actor_type AS actorType,
    actor_id AS actorId, text, source_id AS sourceId, artifact_id AS artifactId, metadata_json AS metadataJson,
    COALESCE((SELECT cr.conversation_revision FROM conversation_work_requests cr WHERE cr.work_request_id = h.work_request_id AND cr.conversation_id = h.conversation_id),0) AS contextRevision
    FROM conversation_history_entries h
    WHERE conversation_id = ?1 AND sequence <= ?2 AND (h.work_request_id IS NULL OR EXISTS
      (SELECT 1 FROM conversation_work_requests cr WHERE cr.conversation_id = h.conversation_id AND cr.work_request_id = h.work_request_id AND cr.conversation_revision <= ?3))
    ORDER BY sequence LIMIT 1001`,
    )
    .bind(conversationId, throughSequence, contextRevision)
    .all<{
      sequence: number;
      contextRevision: number;
      kind: string;
      eventType: string;
      actorType: string;
      actorId: string | null;
      text: string | null;
      metadataJson: string;
    }>();
  const entries = result.results ?? [];
  if (entries.length > 1000)
    throw new Error("Conversation bootstrap exceeds the history limit");
  const history = entries.map(({ metadataJson, ...entry }) => ({
    ...entry,
    metadata: JSON.parse(metadataJson) as Record<string, unknown>,
  })) as ContextHistoryFact[];
  const current = await db
    .prepare(
      `SELECT wr.workflow_id AS workflowId, wr.workflow_version AS workflowVersion,
    wfr.id AS workflowRunId, wr.status, wr.snapshot_json AS snapshotJson, ws.project_id AS projectId, wr.workstream_id AS workstreamId, wr.primary_workspace_id AS workspaceId FROM work_requests wr
    JOIN conversation_workflow_runs wfr ON wfr.work_request_id = wr.id
    JOIN workstreams ws ON ws.id = wr.workstream_id
    JOIN conversation_work_requests cr ON cr.work_request_id = wr.id WHERE cr.conversation_id = ?1 AND wr.id = ?2`,
    )
    .bind(conversationId, workRequestId)
    .first<{
      workflowRunId: string;
      workflowId: string;
      workflowVersion: number;
      status: string;
      snapshotJson: string;
      projectId: string;
      workstreamId: string;
      workspaceId: string | null;
    }>();
  if (!current) throw new Error("Conversation workflow state is missing");
  const tasks = await db
    .prepare(
      `SELECT t.id, t.step_kind AS kind, t.status, t.attempt, t.output_json AS outputJson,
      s.id AS workflowStepRunId,s.role,
      (SELECT worker_id FROM conversation_turns WHERE workflow_step_run_id=s.id ORDER BY rowid DESC LIMIT 1) AS actualWorkerId
      FROM workflow_tasks t JOIN conversation_workflow_step_runs s ON s.task_id=t.id WHERE t.work_request_id = ?1 ORDER BY t.id LIMIT 1001`,
    )
    .bind(workRequestId)
    .all<
      ContextWorkflowState["steps"][number] & {
        outputJson: string | null;
        actualWorkerId: string | null;
        workflowStepRunId: string;
        role: string;
      }
    >();
  if ((tasks.results?.length ?? 0) > 1000)
    throw new Error("Workflow context exceeds the step limit");
  const snapshot = JSON.parse(current.snapshotJson) as Record<string, unknown>;
  const fact = <T>(value: T) => ({
    revision: contextRevision,
    sequence: throughSequence,
    value,
  });
  const seed = {
    ...emptyContextState(),
    objective:
      typeof snapshot.originalRequest === "string"
        ? fact(snapshot.originalRequest)
        : null,
    constraints: Object.fromEntries(
      ["projectInstructions", "workstreamInstructions"].flatMap((key) =>
        typeof snapshot[key] === "string" && snapshot[key]
          ? [[key, fact(snapshot[key] as string)]]
          : [],
      ),
    ),
    currentState: fact(current.status),
    workflowState: fact({
      workflowId: current.workflowId,
      workflowVersion: current.workflowVersion,
      workRequestId,
      status: current.status,
      steps: (tasks.results ?? []).map(
        ({ outputJson: _output, actualWorkerId: _worker, ...step }) => step,
      ),
    }),
  };
  const dependencies = await db
    .prepare(
      `SELECT d.task_id AS taskId, d.depends_on_task_id AS dependencyId
    FROM workflow_task_dependencies d JOIN workflow_tasks t ON t.id = d.task_id WHERE t.work_request_id = ?1 LIMIT 10001`,
    )
    .bind(workRequestId)
    .all<{ taskId: string; dependencyId: string }>();
  if ((dependencies.results?.length ?? 0) > 10000)
    throw new Error("Workflow dependency limit exceeded");
  const taskRows = tasks.results ?? [];
  if (activeStepId && !taskRows.some((step) => step.id === activeStepId))
    throw new Error("Receiving Workflow step is outside this request");
  const selectedStepId =
    activeStepId ?? (taskRows.length === 1 ? taskRows[0]!.id : undefined);
  const artifacts = await db
    .prepare(
      `SELECT id, content_digest AS contentDigest FROM artifacts WHERE work_request_id = ?1 AND project_id = ?2 ORDER BY id LIMIT 1001`,
    )
    .bind(workRequestId, current.projectId)
    .all<{ id: string; contentDigest: string }>();
  if ((artifacts.results?.length ?? 0) > 1000)
    throw new Error("Workflow artifact limit exceeded");
  const bindings = snapshot.resolvedBindings as
    Record<string, { workerId?: string }> | undefined;
  const workflowExecution: WorkflowExecutionContext | undefined = selectedStepId
    ? {
        schemaVersion: 1,
        workflowRunId: current.workflowRunId,
        workflowId: current.workflowId,
        workflowVersion: current.workflowVersion,
        workRequestId,
        status: current.status,
        activeStepId: selectedStepId,
        steps: taskRows.map(({ outputJson, actualWorkerId, ...step }) => {
          const output = outputJson
            ? (JSON.parse(outputJson) as Record<string, unknown>)
            : null;
          const nested = output?.output as { text?: unknown } | undefined;
          return {
            ...step,
            workerId:
              actualWorkerId ??
              (typeof output?.workerId === "string"
                ? output.workerId
                : (bindings?.[
                    current.workflowId === "direct" ? "direct" : step.kind
                  ]?.workerId ?? null)),
            dependsOn: (dependencies.results ?? [])
              .filter((d) => d.taskId === step.id)
              .map((d) => d.dependencyId),
            result:
              step.status === "completed"
                ? typeof output?.text === "string"
                  ? output.text
                  : typeof nested?.text === "string"
                    ? nested.text
                    : null
                : null,
          };
        }),
        environment:
          current.workflowId === "chat"
            ? null
            : {
                projectId: current.projectId,
                workstreamId: current.workstreamId,
                workspaceId: current.workspaceId,
                projectInstructions:
                  typeof snapshot.projectInstructions === "string"
                    ? snapshot.projectInstructions
                    : "",
                workstreamInstructions:
                  typeof snapshot.workstreamInstructions === "string"
                    ? snapshot.workstreamInstructions
                    : "",
              },
        artifacts:
          current.workflowId === "chat" ? [] : (artifacts.results ?? []),
      }
    : undefined;
  const state = projectContextState(history, seed);
  const engine = new ContextEngine();
  const input = {
    conversationId,
    contextRevision,
    throughSequence,
    history,
    state,
    workflowExecution,
  };
  const text = JSON.stringify(
    mode === "stateless" ? engine.stateless(input) : engine.bootstrap(input),
  );
  if (new TextEncoder().encode(text).byteLength > 256 * 1024)
    throw new Error("Conversation bootstrap exceeds the byte limit");
  return {
    schemaVersion: 1,
    conversationId,
    contextRevision,
    throughSequence,
    text,
    turnRevision: boundary.revision,
  };
}
