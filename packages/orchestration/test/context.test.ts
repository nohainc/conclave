import { describe, expect, it } from "vitest";
import {
  ContextAssemblyError,
  ContextBuilder,
  type ContextArtifact,
} from "../src/context.js";

describe("model context assembly", () => {
  it("resolves, deduplicates, and truncates artifacts within limits", async () => {
    const artifacts: ContextArtifact[] = [
      { artifactId: "a", mediaType: "text/plain", content: "abcdefghij" },
      { artifactId: "b", mediaType: "text/plain", content: "12345" },
    ];
    const builder = new ContextBuilder(
      {
        resolve: async (id) =>
          artifacts.find((artifact) => artifact.artifactId === id) ?? null,
      },
      { maxCharsPerArtifact: 6, maxTotalChars: 9, maxEstimatedTokens: 3 },
    );
    await expect(builder.build(["a", "a", "b"])).resolves.toEqual([
      {
        artifactId: "a",
        mediaType: "text/plain",
        content: "abcdef",
        truncated: true,
        originalLength: 10,
        estimatedTokens: 2,
      },
      {
        artifactId: "b",
        mediaType: "text/plain",
        content: "123",
        truncated: true,
        originalLength: 5,
        estimatedTokens: 1,
      },
    ]);
  });

  it("fails closed when an artifact cannot be resolved", async () => {
    const builder = new ContextBuilder({ resolve: async () => null });
    await expect(builder.build(["missing"])).rejects.toThrow(
      ContextAssemblyError,
    );
  });
});
