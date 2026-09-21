import { mkdir, mkdtemp } from "node:fs/promises";
import { realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import {
  GitWorkspaceManager,
  type GitCommandResult,
  type GitRunner,
} from "../src/index.js";

describe("GitWorkspaceManager", () => {
  it("creates isolated worktrees and exposes workspace-scoped repositories", async () => {
    const repositoryRoot = await mkdtemp(join(tmpdir(), "conclave-repo-"));
    const workspaceRoot = await mkdtemp(join(tmpdir(), "conclave-workspaces-"));
    const calls: { args: readonly string[]; cwd: string }[] = [];
    const runGit: GitRunner = async (args, cwd): Promise<GitCommandResult> => {
      calls.push({ args, cwd });
      await mkdir(args[3] ?? workspaceRoot, { recursive: true });
      return { stdout: "", stderr: "", exitCode: 0 };
    };
    const manager = new GitWorkspaceManager({
      repositories: [{ id: "repo-1", root: repositoryRoot }],
      workspaceRoot,
      runGit,
    });

    const workspace = await manager.create({
      workspaceId: "attempt-one",
      repositoryId: "repo-1",
      revision: "main",
    });
    const repository = manager.asRuntimeRepository("attempt-one");

    expect(calls[0]?.args).toEqual([
      "worktree",
      "add",
      "--detach",
      join(realpathSync(workspaceRoot), "repo-1", "attempt-one"),
      "main",
    ]);
    expect(calls[0]?.cwd).toBe(realpathSync(repositoryRoot));
    expect(repository.id).toBe("repo-1::attempt-one");
    expect(repository.root).toBe(workspace.root);
  });

  it("rejects unsafe IDs and removes only tracked worktrees", async () => {
    const repositoryRoot = await mkdtemp(join(tmpdir(), "conclave-repo-"));
    const workspaceRoot = await mkdtemp(join(tmpdir(), "conclave-workspaces-"));
    const calls: readonly string[][] = [];
    const runGit: GitRunner = async (args): Promise<GitCommandResult> => {
      (calls as string[][]).push([...args]);
      await mkdir(args[3] ?? workspaceRoot, { recursive: true });
      return { stdout: "", stderr: "", exitCode: 0 };
    };
    const manager = new GitWorkspaceManager({
      repositories: [{ id: "repo-1", root: repositoryRoot }],
      workspaceRoot,
      runGit,
    });

    await expect(
      manager.create({
        workspaceId: "../escape",
        repositoryId: "repo-1",
        revision: "main",
      }),
    ).rejects.toThrow("safe path segments");
    await manager.create({
      workspaceId: "attempt-one",
      repositoryId: "repo-1",
      revision: "main",
    });
    await manager.remove("attempt-one");
    expect(calls[1]?.slice(0, 3)).toEqual(["worktree", "remove", "--force"]);
    expect(manager.list()).toHaveLength(0);
  });
});
