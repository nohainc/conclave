import type { PlanResult } from "@conclave/protocol";
import {
  type Finding,
  type VerificationPolicy,
  type VerificationRecord,
  VerificationGate,
} from "./verification.js";

export type GraphTaskStatus =
  | "pending"
  | "ready"
  | "running"
  | "succeeded"
  | "blocked"
  | "failed"
  | "cancelled";

export type GraphRunStatus = "active" | "succeeded" | "failed" | "cancelled";

export interface GraphTask {
  readonly taskId: string;
  readonly phaseId: string;
  readonly phaseOrder: number;
  readonly taskOrder: number;
  readonly objective: string;
  readonly role: string;
  readonly capabilities: readonly string[];
  readonly dependsOnTaskIds: readonly string[];
  readonly requiresIndependentVerification: boolean;
}

export interface GraphPhase {
  readonly phaseId: string;
  readonly name: string;
  readonly purpose: string;
  readonly order: number;
}

export interface ValidatedTaskGraph {
  readonly phases: readonly GraphPhase[];
  readonly tasks: readonly GraphTask[];
}

export function validateTaskGraph(plan: PlanResult): ValidatedTaskGraph {
  const phaseIds = new Set<string>();
  const taskIds = new Set<string>();
  const phases: GraphPhase[] = [];
  const tasks: GraphTask[] = [];

  plan.payload.phases.forEach((phase, phaseOrder) => {
    if (phaseIds.has(phase.phaseId)) {
      throw new Error(`Duplicate phase id: ${phase.phaseId}`);
    }
    phaseIds.add(phase.phaseId);
    phases.push({
      phaseId: phase.phaseId,
      name: phase.name,
      purpose: phase.purpose,
      order: phaseOrder,
    });

    phase.tasks.forEach((task, taskOrder) => {
      if (taskIds.has(task.taskId)) {
        throw new Error(`Duplicate task id: ${task.taskId}`);
      }
      taskIds.add(task.taskId);
      tasks.push({ ...task, phaseId: phase.phaseId, phaseOrder, taskOrder });
    });
  });

  const taskById = new Map(tasks.map((task) => [task.taskId, task]));
  for (const task of tasks) {
    for (const dependencyId of task.dependsOnTaskIds) {
      if (dependencyId === task.taskId) {
        throw new Error(`Task cannot depend on itself: ${task.taskId}`);
      }
      if (!taskById.has(dependencyId)) {
        throw new Error(
          `Unknown dependency ${dependencyId} for task ${task.taskId}`,
        );
      }
    }
  }

  const visiting = new Set<string>();
  const visited = new Set<string>();
  const visit = (taskId: string): void => {
    if (visiting.has(taskId))
      throw new Error(`Task dependency cycle includes ${taskId}`);
    if (visited.has(taskId)) return;
    visiting.add(taskId);
    for (const dependencyId of taskById.get(taskId)?.dependsOnTaskIds ?? [])
      visit(dependencyId);
    visiting.delete(taskId);
    visited.add(taskId);
  };
  for (const task of tasks) visit(task.taskId);

  return { phases, tasks };
}

export interface TaskExecutionPolicy {
  readonly maxAttemptsPerTask: number;
  readonly maxTotalAttempts: number;
  readonly maxCostMicros: number;
  readonly timeoutMs: number;
  readonly verificationPolicy?: VerificationPolicy;
}

export interface TaskState {
  readonly task: GraphTask;
  readonly status: GraphTaskStatus;
  readonly attempts: number;
  readonly startedAt: string | null;
  readonly finishedAt: string | null;
  readonly failureClass: string | null;
  readonly reopenCount: number;
}

export interface TaskGraphSnapshot {
  readonly runStatus: GraphRunStatus;
  readonly totalAttempts: number;
  readonly totalCostMicros: number;
  readonly tasks: readonly TaskState[];
}

export class TaskGraphState {
  private readonly taskStates = new Map<string, TaskState>();
  private runStatus: GraphRunStatus = "active";
  private totalAttempts = 0;
  private totalCostMicros = 0;
  readonly verification: VerificationGate | null;

  constructor(
    readonly graph: ValidatedTaskGraph,
    readonly policy: TaskExecutionPolicy,
  ) {
    for (const task of graph.tasks) {
      this.taskStates.set(task.taskId, {
        task,
        status: "pending",
        attempts: 0,
        startedAt: null,
        finishedAt: null,
        failureClass: null,
        reopenCount: 0,
      });
    }
    if (
      policy.maxAttemptsPerTask < 1 ||
      policy.maxTotalAttempts < 1 ||
      policy.timeoutMs < 1
    ) {
      throw new Error("Task execution limits must be positive");
    }
    this.verification = policy.verificationPolicy
      ? new VerificationGate(policy.verificationPolicy)
      : null;
  }

  snapshot(): TaskGraphSnapshot {
    return {
      runStatus: this.runStatus,
      totalAttempts: this.totalAttempts,
      totalCostMicros: this.totalCostMicros,
      tasks: this.graph.tasks.map((task) => this.taskStates.get(task.taskId)!),
    };
  }

  readyTasks(): readonly TaskState[] {
    if (this.runStatus !== "active") return [];
    for (const state of this.taskStates.values()) {
      if (
        state.status === "pending" &&
        state.task.dependsOnTaskIds.some((dependencyId) => {
          const dependency = this.taskStates.get(dependencyId);
          return (
            dependency?.status === "failed" ||
            dependency?.status === "cancelled"
          );
        })
      ) {
        this.replace(state.task.taskId, {
          status: "blocked",
          failureClass: "dependency",
        });
      }
    }
    return this.graph.tasks
      .map((task) => this.taskStates.get(task.taskId)!)
      .filter(
        (state) =>
          state.status === "pending" &&
          state.task.dependsOnTaskIds.every(
            (dependencyId) =>
              this.taskStates.get(dependencyId)?.status === "succeeded",
          ),
      )
      .map((state) => ({ ...state, status: "ready" as const }));
  }

  startTask(taskId: string, startedAt: string): TaskState {
    this.assertActive();
    const state = this.requireTask(taskId);
    if (state.status !== "pending" && state.status !== "ready") {
      throw new Error(`Task ${taskId} is not ready to start`);
    }
    if (
      !state.task.dependsOnTaskIds.every(
        (dependencyId) =>
          this.taskStates.get(dependencyId)?.status === "succeeded",
      )
    ) {
      throw new Error(`Task ${taskId} dependencies are incomplete`);
    }
    if (this.totalAttempts >= this.policy.maxTotalAttempts) {
      this.runStatus = "failed";
      throw new Error("Run attempt budget exhausted");
    }
    const next: TaskState = {
      ...state,
      status: "running",
      attempts: state.attempts + 1,
      startedAt,
      finishedAt: null,
      failureClass: null,
    };
    this.totalAttempts += 1;
    this.taskStates.set(taskId, next);
    return next;
  }

  completeTask(
    taskId: string,
    finishedAt: string,
    costMicros: number,
  ): TaskState {
    const state = this.requireRunning(taskId);
    this.verification?.assertCanComplete(taskId);
    this.totalCostMicros += costMicros;
    if (this.totalCostMicros > this.policy.maxCostMicros) {
      return this.failTask(taskId, finishedAt, "budget", 0);
    }
    const next = { ...state, status: "succeeded" as const, finishedAt };
    this.taskStates.set(taskId, next);
    if (
      [...this.taskStates.values()].every((task) => task.status === "succeeded")
    ) {
      this.runStatus = "succeeded";
    }
    return next;
  }

  failTask(
    taskId: string,
    finishedAt: string,
    failureClass: string,
    costMicros: number,
  ): TaskState {
    const state = this.requireRunning(taskId);
    this.totalCostMicros += costMicros;
    const exhausted =
      state.attempts >= this.policy.maxAttemptsPerTask ||
      this.totalAttempts >= this.policy.maxTotalAttempts ||
      this.totalCostMicros > this.policy.maxCostMicros;
    const next = {
      ...state,
      status: exhausted ? ("failed" as const) : ("pending" as const),
      finishedAt,
      failureClass,
    };
    this.taskStates.set(taskId, next);
    if (exhausted) this.runStatus = "failed";
    return next;
  }

  cancelRun(): TaskGraphSnapshot {
    if (this.runStatus === "succeeded")
      throw new Error("Completed run cannot be cancelled");
    this.runStatus = "cancelled";
    for (const state of this.taskStates.values()) {
      if (state.status !== "succeeded" && state.status !== "failed") {
        this.replace(state.task.taskId, {
          status: "cancelled",
          failureClass: "cancelled",
        });
      }
    }
    return this.snapshot();
  }

  reopenTask(taskId: string): TaskState {
    const state = this.requireTask(taskId);
    if (!["failed", "blocked", "succeeded"].includes(state.status)) {
      throw new Error(`Task ${taskId} cannot be reopened from ${state.status}`);
    }
    if (this.runStatus === "cancelled")
      throw new Error("Cancelled run cannot reopen tasks");
    this.runStatus = "active";
    const next = {
      ...state,
      status: "pending" as const,
      finishedAt: null,
      failureClass: "reopened",
      reopenCount: state.reopenCount + 1,
    };
    this.taskStates.set(taskId, next);
    return next;
  }

  openFinding(finding: Finding): void {
    if (this.verification === null)
      throw new Error("No verification policy is configured");
    this.verification.openFinding(finding);
  }

  recordVerification(record: VerificationRecord): void {
    if (this.verification === null)
      throw new Error("No verification policy is configured");
    this.verification.recordVerification(record);
  }

  fixFinding(findingId: string): Finding {
    if (this.verification === null)
      throw new Error("No verification policy is configured");
    return this.verification.fixFinding(findingId);
  }

  verifyFinding(findingId: string): Finding {
    if (this.verification === null)
      throw new Error("No verification policy is configured");
    return this.verification.verifyFinding(findingId);
  }

  reopenFinding(findingId: string): Finding {
    if (this.verification === null)
      throw new Error("No verification policy is configured");
    return this.verification.reopenFinding(findingId);
  }

  timeoutTasks(nowMs: number, timestamp: string): readonly TaskState[] {
    const timedOut: TaskState[] = [];
    for (const state of this.taskStates.values()) {
      if (state.status !== "running" || state.startedAt === null) continue;
      if (nowMs - Date.parse(state.startedAt) >= this.policy.timeoutMs) {
        timedOut.push(
          this.failTask(state.task.taskId, timestamp, "timeout", 0),
        );
      }
    }
    return timedOut;
  }

  private replace(taskId: string, patch: Partial<TaskState>): void {
    const state = this.requireTask(taskId);
    this.taskStates.set(taskId, { ...state, ...patch });
  }

  private requireTask(taskId: string): TaskState {
    const state = this.taskStates.get(taskId);
    if (state === undefined) throw new Error(`Unknown task: ${taskId}`);
    return state;
  }

  private requireRunning(taskId: string): TaskState {
    const state = this.requireTask(taskId);
    if (state.status !== "running")
      throw new Error(`Task ${taskId} is not running`);
    return state;
  }

  private assertActive(): void {
    if (this.runStatus !== "active")
      throw new Error(`Run is ${this.runStatus}`);
  }
}

export interface TaskGraphExecutorResult {
  readonly outcome: "succeeded" | "failed";
  readonly costMicros?: number;
  readonly failureClass?: string;
}

export async function executeTaskGraph(
  state: TaskGraphState,
  executor: (
    task: GraphTask,
    attempt: number,
    timeoutMs: number,
  ) => Promise<TaskGraphExecutorResult>,
  now: () => string,
): Promise<TaskGraphSnapshot> {
  while (state.snapshot().runStatus === "active") {
    const ready = state.readyTasks();
    if (ready.length === 0) {
      const snapshot = state.snapshot();
      if (snapshot.tasks.some((task) => task.status === "blocked")) {
        throw new Error("Task graph is blocked by a failed dependency");
      }
      if (snapshot.tasks.every((task) => task.status === "succeeded"))
        return snapshot;
      throw new Error("Task graph cannot make deterministic progress");
    }

    const task = ready[0]!;
    const started = state.startTask(task.task.taskId, now());
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const result = await Promise.race([
        executor(started.task, started.attempts, state.policy.timeoutMs),
        new Promise<TaskGraphExecutorResult>((resolve) => {
          timer = setTimeout(
            () => resolve({ outcome: "failed", failureClass: "timeout" }),
            state.policy.timeoutMs,
          );
        }),
      ]);
      if (result.outcome === "succeeded") {
        state.completeTask(task.task.taskId, now(), result.costMicros ?? 0);
      } else {
        state.failTask(
          task.task.taskId,
          now(),
          result.failureClass ?? "worker",
          result.costMicros ?? 0,
        );
      }
    } finally {
      if (timer !== undefined) clearTimeout(timer);
    }
  }
  return state.snapshot();
}
