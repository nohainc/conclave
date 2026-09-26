/**
 * Immutable input and planning boundary for v6 stateless fan-out.
 *
 * Stateless Workers consume a repository/context snapshot. They never receive
 * a Primary Workstream checkout path, so Primary mutation cannot affect an
 * already planned research or review attempt.
 */

export type StatelessSnapshotMechanism =
  "r2_context_artifacts" | "repository_snapshot";

export interface StatelessContextArtifact {
  readonly id: string;
  readonly sha256: string;
  readonly kind: string;
}

export interface StatelessRepositorySnapshot {
  readonly mechanism: StatelessSnapshotMechanism;
  readonly repositoryId: string;
  readonly revision: string;
  readonly checkpointSha: string;
  readonly snapshotId: string;
}

export interface StatelessFanOutCandidate {
  readonly workspaceId: string;
  readonly workerId: string;
  readonly accountId: string;
  readonly providerKey: string;
  readonly capabilities: readonly string[];
}

export interface StatelessFanOutRequest {
  readonly projectId: string;
  readonly workstreamId: string;
  readonly workRequestId: string;
  readonly primaryWorkspaceId: string;
  readonly checkpointSha: string;
  readonly currentCheckpointSha: string;
  readonly repositorySnapshot: StatelessRepositorySnapshot;
  readonly contextArtifacts: readonly StatelessContextArtifact[];
  readonly authorizedArtifactIds: readonly string[];
  readonly requiredCapabilities: readonly string[];
  readonly requireIndependentProviders: boolean;
  readonly candidates: readonly StatelessFanOutCandidate[];
}

export interface StatelessFanOutAssignment {
  readonly assignmentId: string;
  readonly projectId: string;
  readonly workstreamId: string;
  readonly workRequestId: string;
  readonly executionClass: "stateless_read";
  readonly workspaceId: string;
  readonly workerId: string;
  readonly accountId: string;
  readonly providerKey: string;
  readonly snapshot: {
    readonly checkpointSha: string;
    readonly repositorySnapshotId: string;
    readonly repositoryRevision: string;
    readonly contextArtifactIds: readonly string[];
  };
}

export interface StatelessFanOutPlan {
  readonly snapshot: StatelessFanOutAssignment["snapshot"];
  readonly assignments: readonly StatelessFanOutAssignment[];
}

/** Creates a deterministic, immutable plan for auxiliary stateless Workers. */
export function planStatelessFanOut(
  input: StatelessFanOutRequest,
  assignmentId = (index: number) =>
    `${input.workRequestId}:stateless:${index + 1}`,
): StatelessFanOutPlan {
  if (!input.projectId || !input.workstreamId || !input.workRequestId) {
    throw new Error(
      "Stateless fan-out requires Project, Workstream, and Work Request IDs",
    );
  }
  if (
    !input.checkpointSha ||
    input.checkpointSha !== input.currentCheckpointSha
  ) {
    throw new Error("Stateless fan-out snapshot is stale");
  }
  if (
    !input.repositorySnapshot.snapshotId ||
    input.repositorySnapshot.checkpointSha !== input.checkpointSha
  ) {
    throw new Error("Repository snapshot does not match the Checkpoint SHA");
  }
  if (
    input.repositorySnapshot.mechanism !== "r2_context_artifacts" &&
    input.repositorySnapshot.mechanism !== "repository_snapshot"
  ) {
    throw new Error("Unsupported stateless snapshot mechanism");
  }
  if (
    input.repositorySnapshot.snapshotId.includes("/") ||
    input.repositorySnapshot.snapshotId.includes("\\")
  ) {
    throw new Error("Repository snapshot ID must be opaque");
  }

  const authorized = new Set(input.authorizedArtifactIds);
  const artifactIds = [...input.contextArtifacts]
    .sort((left, right) => left.id.localeCompare(right.id))
    .map((artifact) => {
      if (!authorized.has(artifact.id)) {
        throw new Error(`Context artifact is not authorized: ${artifact.id}`);
      }
      return artifact.id;
    });
  const required = [...new Set(input.requiredCapabilities)].map((value) =>
    value.toLowerCase(),
  );
  const candidates = [...input.candidates]
    .filter((candidate) => candidate.workspaceId !== input.primaryWorkspaceId)
    .filter((candidate) =>
      required.every((capability) =>
        candidate.capabilities
          .map((value) => value.toLowerCase())
          .includes(capability),
      ),
    )
    .sort((left, right) =>
      `${left.providerKey}:${left.workspaceId}:${left.workerId}`.localeCompare(
        `${right.providerKey}:${right.workspaceId}:${right.workerId}`,
      ),
    );

  if (input.requireIndependentProviders) {
    const seenProviders = new Set<string>();
    for (const candidate of candidates) {
      if (seenProviders.has(candidate.providerKey)) continue;
      seenProviders.add(candidate.providerKey);
    }
    if (seenProviders.size < Math.min(2, candidates.length)) {
      throw new Error("Independent provider requirement cannot be satisfied");
    }
  }

  const snapshot = {
    checkpointSha: input.checkpointSha,
    repositorySnapshotId: input.repositorySnapshot.snapshotId,
    repositoryRevision: input.repositorySnapshot.revision,
    contextArtifactIds: artifactIds,
  } as const;
  return {
    snapshot,
    assignments: candidates.map((candidate, index) => ({
      assignmentId: assignmentId(index),
      projectId: input.projectId,
      workstreamId: input.workstreamId,
      workRequestId: input.workRequestId,
      executionClass: "stateless_read" as const,
      workspaceId: candidate.workspaceId,
      workerId: candidate.workerId,
      accountId: candidate.accountId,
      providerKey: candidate.providerKey,
      snapshot,
    })),
  };
}
