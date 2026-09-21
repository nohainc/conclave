import { mkdir, realpath } from "node:fs/promises";
import { realpathSync } from "node:fs";
import { spawn } from "node:child_process";
import { join, relative, resolve, sep } from "node:path";

import type { RuntimeRepository } from "./index.js";

export interface GitCommandResult {
  readonly stdout: string;
  readonly stderr: string;
  readonly exitCode: number;
}

export type GitRunner = (
  args: readonly string[],
  cwd: string,
) => Promise<GitCommandResult>;

export interface GitWorkspace {
  readonly workspaceId: string;
  readonly repositoryId: string;
  readonly root: string;
  readonly revision: string;
}

export interface GitWorkspaceManagerOptions {
  readonly repositories: readonly RuntimeRepository[];
  readonly workspaceRoot: string;
  readonly runGit?: GitRunner;
}

export class GitWorkspaceError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "GitWorkspaceError";
  }
}

function validSegment(value: string): boolean {
  return /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(value);
}

const defaultGitRunner: GitRunner = (args, cwd) =>
  new Promise((resolveResult) => {
    const child = spawn("git", [...args], {
      cwd,
      shell: false,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk: Buffer) => (stdout += chunk.toString()));
    child.stderr.on("data", (chunk: Buffer) => (stderr += chunk.toString()));
    child.on("error", (error) =>
      resolveResult({
        stdout,
        stderr: `${stderr}${error.message}`,
        exitCode: -1,
      }),
    );
    child.on("close", (exitCode) =>
      resolveResult({ stdout, stderr, exitCode: exitCode ?? -1 }),
    );
  });

export class GitWorkspaceManager {
  private readonly repositories: ReadonlyMap<string, RuntimeRepository>;
  private readonly workspaceRoot: string;
  private readonly runGit: GitRunner;
  private readonly workspaces = new Map<string, GitWorkspace>();

  constructor(options: GitWorkspaceManagerOptions) {
    this.workspaceRoot = realpathSync(resolve(options.workspaceRoot));
    this.runGit = options.runGit ?? defaultGitRunner;
    this.repositories = new Map(
      options.repositories.map((repository) => [
        repository.id,
        { ...repository, root: realpathSync(resolve(repository.root)) },
      ]),
    );
  }

  async create(input: {
    readonly workspaceId: string;
    readonly repositoryId: string;
    readonly revision: string;
  }): Promise<GitWorkspace> {
    if (!validSegment(input.workspaceId) || !validSegment(input.repositoryId)) {
      throw new GitWorkspaceError(
        "Workspace and repository IDs must be safe path segments",
      );
    }
    if (this.workspaces.has(input.workspaceId)) {
      throw new GitWorkspaceError(
        `Workspace ${input.workspaceId} already exists`,
      );
    }
    const repository = this.repositories.get(input.repositoryId);
    if (!repository) {
      throw new GitWorkspaceError(
        `Repository ${input.repositoryId} is not registered`,
      );
    }
    const root = resolve(
      this.workspaceRoot,
      input.repositoryId,
      input.workspaceId,
    );
    const relativeRoot = relative(this.workspaceRoot, root);
    if (relativeRoot.startsWith(`..${sep}`) || relativeRoot === "..") {
      throw new GitWorkspaceError("Workspace path escapes workspace root");
    }
    await mkdir(join(this.workspaceRoot, input.repositoryId), {
      recursive: true,
    });
    const result = await this.runGit(
      ["worktree", "add", "--detach", root, input.revision],
      repository.root,
    );
    if (result.exitCode !== 0) {
      throw new GitWorkspaceError(
        result.stderr || "Unable to create Git workspace",
      );
    }
    const workspace = {
      workspaceId: input.workspaceId,
      repositoryId: input.repositoryId,
      root: await realpath(root),
      revision: input.revision,
    } satisfies GitWorkspace;
    this.workspaces.set(input.workspaceId, workspace);
    return workspace;
  }

  async remove(workspaceId: string): Promise<void> {
    const workspace = this.workspaces.get(workspaceId);
    if (!workspace)
      throw new GitWorkspaceError(`Workspace ${workspaceId} is not tracked`);
    const repository = this.repositories.get(workspace.repositoryId);
    if (!repository)
      throw new GitWorkspaceError("Workspace repository is not registered");
    const result = await this.runGit(
      ["worktree", "remove", "--force", workspace.root],
      repository.root,
    );
    if (result.exitCode !== 0) {
      throw new GitWorkspaceError(
        result.stderr || "Unable to remove Git workspace",
      );
    }
    this.workspaces.delete(workspaceId);
  }

  list(): readonly GitWorkspace[] {
    return [...this.workspaces.values()];
  }

  asRuntimeRepository(workspaceId: string): RuntimeRepository {
    const workspace = this.workspaces.get(workspaceId);
    if (!workspace)
      throw new GitWorkspaceError(`Workspace ${workspaceId} is not tracked`);
    return {
      id: `${workspace.repositoryId}::${workspace.workspaceId}`,
      root: workspace.root,
      revision: workspace.revision,
    };
  }
}
