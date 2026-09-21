export interface ContextArtifact {
  readonly artifactId: string;
  readonly mediaType: string;
  readonly content: string;
}

export interface ArtifactResolver {
  resolve(artifactId: string): Promise<ContextArtifact | null>;
}

export interface ModelContextItem {
  readonly artifactId: string;
  readonly mediaType: string;
  readonly content: string;
  readonly truncated: boolean;
  readonly originalLength: number;
  readonly estimatedTokens: number;
}

export interface ContextLimits {
  readonly maxArtifacts?: number;
  readonly maxCharsPerArtifact?: number;
  readonly maxTotalChars?: number;
  readonly maxEstimatedTokens?: number;
}

export class ContextAssemblyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ContextAssemblyError";
  }
}

export class ContextBuilder {
  private readonly limits: Required<ContextLimits>;

  constructor(
    private readonly resolver: ArtifactResolver,
    limits: ContextLimits = {},
  ) {
    this.limits = {
      maxArtifacts: limits.maxArtifacts ?? 12,
      maxCharsPerArtifact: limits.maxCharsPerArtifact ?? 20_000,
      maxTotalChars: limits.maxTotalChars ?? 60_000,
      maxEstimatedTokens: limits.maxEstimatedTokens ?? 15_000,
    };
    if (
      this.limits.maxArtifacts < 1 ||
      this.limits.maxCharsPerArtifact < 1 ||
      this.limits.maxTotalChars < 1 ||
      this.limits.maxEstimatedTokens < 1
    ) {
      throw new Error("Context limits must be positive");
    }
  }

  async build(
    artifactIds: readonly string[],
  ): Promise<readonly ModelContextItem[]> {
    const uniqueIds = [...new Set(artifactIds)];
    if (uniqueIds.length > this.limits.maxArtifacts) {
      throw new ContextAssemblyError(
        `Context references ${uniqueIds.length} artifacts; limit is ${this.limits.maxArtifacts}`,
      );
    }
    const context: ModelContextItem[] = [];
    let totalChars = 0;
    let totalEstimatedTokens = 0;
    for (const artifactId of uniqueIds) {
      const artifact = await this.resolver.resolve(artifactId);
      if (!artifact) {
        throw new ContextAssemblyError(
          `Artifact ${artifactId} could not be resolved`,
        );
      }
      const remaining = this.limits.maxTotalChars - totalChars;
      const remainingTokens =
        this.limits.maxEstimatedTokens - totalEstimatedTokens;
      if (remaining <= 0 || remainingTokens <= 0) break;
      const limit = Math.min(
        this.limits.maxCharsPerArtifact,
        remaining,
        remainingTokens * 4,
      );
      const content = artifact.content.slice(0, limit);
      const estimatedTokens = Math.ceil(content.length / 4);
      context.push({
        artifactId: artifact.artifactId,
        mediaType: artifact.mediaType,
        content,
        truncated: content.length < artifact.content.length,
        originalLength: artifact.content.length,
        estimatedTokens,
      });
      totalChars += content.length;
      totalEstimatedTokens += estimatedTokens;
    }
    return context;
  }
}
