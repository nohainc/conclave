/** Executable contract for the V6-24 solo clean-room journey. */

export const V6_SOLO_ACCEPTANCE_PHASES = [
  "signed_in",
  "workspace_created",
  "worker_account_connected",
  "project_created",
  "workspace_granted",
  "workstream_created",
  "working_directory_ready",
  "discussion_recorded",
  "work_request_created",
  "workflow_completed",
  "checkpoint_created",
  "second_iteration_started",
  "pull_request_created",
] as const;

export type V6SoloAcceptancePhase = (typeof V6_SOLO_ACCEPTANCE_PHASES)[number];

export interface V6SoloAcceptanceRun {
  readonly userId: string;
  readonly workspaceId: string;
  readonly projectId: string;
  readonly workstreamId: string;
  readonly workingDirectoryReady: boolean;
  readonly firstCheckpointRevision: string;
  readonly secondRequestBaseCheckpointRevision: string;
  readonly pullRequestUrl: string;
  readonly completedPhases: readonly V6SoloAcceptancePhase[];
}

export function validateV6SoloAcceptance(run: V6SoloAcceptanceRun): void {
  const required = [
    [run.userId, "user"],
    [run.workspaceId, "workspace"],
    [run.projectId, "project"],
    [run.workstreamId, "workstream"],
    [run.workingDirectoryReady ? "ready" : "", "working directory"],
    [run.firstCheckpointRevision, "first checkpoint revision"],
    [run.pullRequestUrl, "pull request URL"],
  ] as const;
  for (const [value, label] of required) {
    if (!value.trim()) throw new Error(`${label} is required`);
  }
  if (run.secondRequestBaseCheckpointRevision !== run.firstCheckpointRevision) {
    throw new Error("second iteration must start from the first checkpoint");
  }
  for (const phase of V6_SOLO_ACCEPTANCE_PHASES) {
    if (!run.completedPhases.includes(phase)) {
      throw new Error(`clean-room acceptance is incomplete: ${phase}`);
    }
  }
}
