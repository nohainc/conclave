import { describe, expect, it, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { AgentUpdater, type AgentReleaseInfo } from "../src/updater.js";
import { loadAgentConfig } from "../src/config.js";
import { AgentLogger } from "../src/logger.js";
import { AgentStorage } from "../src/storage.js";
import { WorkerManager } from "../src/worker-manager.js";
import { computePackageDigest, signPackageDigest } from "@conclave/security";

describe("Architecture v2 Agent Self-Update & Rollback Engine", () => {
  let tmpDir: string;
  let config: ReturnType<typeof loadAgentConfig>;
  let logger: AgentLogger;
  let storage: AgentStorage;
  let workerManager: WorkerManager;
  let updater: AgentUpdater;

  const signingKey = "test-signing-secret-key-123";

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "conclave-agent-updater-test-"),
    );
    config = loadAgentConfig({
      homeDir: tmpDir,
      cloudUrl: "https://conclave.test",
      agentToken: "test-token",
    });
    logger = new AgentLogger(config.logDir);
    storage = new AgentStorage(config);
    storage.ensureDirectories();
    workerManager = new WorkerManager(config, storage, logger);
    updater = new AgentUpdater(config, logger, workerManager, signingKey);
  });

  afterEach(() => {
    if (fs.existsSync(tmpDir)) {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("stages a release and manages updates directories", async () => {
    const pkg = Buffer.from("conclave-agent-binary-1.3.0");
    const digest = await computePackageDigest(pkg);
    const signature = await signPackageDigest(digest, signingKey);

    const release: AgentReleaseInfo = {
      version: "1.3.0",
      channel: "stable",
      supportedOS: ["macos", "linux", "windows"],
      supportedArch: ["arm64", "x64"],
      packageDigest: digest,
      packageR2Key: "agent/releases/1.3.0.tar.gz",
      signature,
      releaseNotes: "v1.3.0 upgrade",
    };

    const stagedDir = await updater.stageRelease(release, pkg);
    expect(fs.existsSync(stagedDir)).toBe(true);
    expect(fs.existsSync(path.join(stagedDir, "release.bin"))).toBe(true);
    expect(fs.existsSync(path.join(stagedDir, "release-manifest.json"))).toBe(
      true,
    );

    const manifest = JSON.parse(
      fs.readFileSync(path.join(stagedDir, "release-manifest.json"), "utf8"),
    ) as AgentReleaseInfo;
    expect(manifest.version).toBe("1.3.0");
  });

  it("verifies package digest and HMAC cryptographic signatures", async () => {
    const pkg = Buffer.from("valid-agent-bundle-1.4.0");
    const digest = await computePackageDigest(pkg);
    const validSignature = await signPackageDigest(digest, signingKey);

    const validRelease: AgentReleaseInfo = {
      version: "1.4.0",
      channel: "stable",
      supportedOS: ["macos", "linux"],
      supportedArch: ["arm64", "x64"],
      packageDigest: digest,
      packageR2Key: "agent/releases/1.4.0.tar.gz",
      signature: validSignature,
    };

    // Valid package
    const isValid = await updater.verifyRelease(pkg, validRelease);
    expect(isValid).toBe(true);

    // Tampered package content
    const tamperedPkg = Buffer.from("tampered-agent-bundle-1.4.0");
    const isTamperedValid = await updater.verifyRelease(
      tamperedPkg,
      validRelease,
    );
    expect(isTamperedValid).toBe(false);

    // Forged signature
    const forgedRelease: AgentReleaseInfo = {
      ...validRelease,
      signature: "sig_pkg_forged_hex_signature",
    };
    const isForgedValid = await updater.verifyRelease(pkg, forgedRelease);
    expect(isForgedValid).toBe(false);
  });

  it("drains active assignments before update application", async () => {
    // Configure worker
    workerManager.configureWorker({
      workerId: "w-drain-test",
      pluginId: "plugin-test",
      pluginVersionPolicy: "latest",
      name: "Drain Test Worker",
      roles: ["tester"],
      capabilities: ["test_execution"],
      config: {},
      secretRefs: [],
      billingMode: "free",
      independenceKey: "drain-test",
      concurrencyLimit: 2,
      enabled: true,
    });

    // Run short-lived assignment
    let assignmentFinished = false;
    workerManager.setExecutor(async () => {
      await new Promise((resolve) => setTimeout(resolve, 50));
      assignmentFinished = true;
      return { output: { done: true }, summary: "Finished" };
    });

    const execPromise = workerManager.executeAssignment({
      assignmentId: "asg-drain-1",
      workerId: "w-drain-test",
      runId: "run-1",
      taskId: "task-1",
      attemptId: "att-1",
      idempotencyKey: "idemp-drain-1",
      payload: {
        objective: "Drain test",
        role: "tester",
        pluginId: "plugin-test",
        resolvedPluginVersion: "1.0.0",
        input: {},
        contextArtifactIds: [],
        timeoutMs: 5000,
      },
    });

    expect(workerManager.getActiveAssignmentsCount()).toBe(1);

    // Drain should await completion
    const drained = await updater.drainActiveWork(1000);
    expect(drained).toBe(true);
    expect(assignmentFinished).toBe(true);
    expect(workerManager.getActiveAssignmentsCount()).toBe(0);

    await execPromise;
  });

  it("executes atomic cutover and rollback on health check failure", async () => {
    // 1. Setup initial active version v1.2.0 in current directory
    const currentDir = path.join(tmpDir, "updates", "current");
    fs.mkdirSync(currentDir, { recursive: true });
    fs.writeFileSync(
      path.join(currentDir, "release.bin"),
      "v1.2.0-initial-binary",
    );
    fs.writeFileSync(
      path.join(currentDir, "release-manifest.json"),
      JSON.stringify({ version: "1.2.0" }),
    );

    // 2. Stage v1.3.0
    const pkg130 = Buffer.from("v1.3.0-new-binary");
    const digest130 = await computePackageDigest(pkg130);
    const sig130 = await signPackageDigest(digest130, signingKey);

    const release130: AgentReleaseInfo = {
      version: "1.3.0",
      channel: "stable",
      supportedOS: ["macos", "linux"],
      supportedArch: ["arm64", "x64"],
      packageDigest: digest130,
      packageR2Key: "agent/releases/1.3.0.tar.gz",
      signature: sig130,
    };

    const stagedDir = await updater.stageRelease(release130, pkg130);

    // 3. Apply update
    await updater.applyUpdate(release130, stagedDir, "1.2.0");

    // Current now contains v1.3.0 and previous contains v1.2.0
    expect(fs.readFileSync(path.join(currentDir, "release.bin"), "utf8")).toBe(
      "v1.3.0-new-binary",
    );
    expect(
      fs.readFileSync(
        path.join(tmpDir, "updates", "previous", "release.bin"),
        "utf8",
      ),
    ).toBe("v1.2.0-initial-binary");

    // 4. Simulate health check failure and trigger rollback
    const rollbackSuccess = await updater.rollback("1.2.0");
    expect(rollbackSuccess).toBe(true);

    // Current has been restored to v1.2.0
    expect(fs.readFileSync(path.join(currentDir, "release.bin"), "utf8")).toBe(
      "v1.2.0-initial-binary",
    );
  });

  it("completes end-to-end self-update workflow successfully", async () => {
    const currentVersion = "1.2.0";
    const targetVersion = "1.3.0";

    const pkg = Buffer.from("conclave-agent-v1.3.0-executable-bundle");
    const digest = await computePackageDigest(pkg);
    const signature = await signPackageDigest(digest, signingKey);

    const release: AgentReleaseInfo = {
      version: targetVersion,
      channel: "stable",
      supportedOS: ["macos", "linux", "windows"],
      supportedArch: ["arm64", "x64"],
      packageDigest: digest,
      packageR2Key: "agent/releases/1.3.0.tar.gz",
      signature,
    };

    // Mock checkForUpdates & downloadRelease
    updater.checkForUpdates = async () => release;
    updater.downloadRelease = async () => pkg;

    const phases: string[] = [];
    const result = await updater.performSelfUpdate({
      currentVersion,
      channel: "stable",
      signingKey,
      onPhaseChange: (phase) => {
        phases.push(phase);
      },
      customHealthCheck: async () => true,
    });

    expect(result.success).toBe(true);
    expect(result.previousVersion).toBe("1.2.0");
    expect(result.targetVersion).toBe("1.3.0");

    expect(phases).toContain("checking");
    expect(phases).toContain("downloading");
    expect(phases).toContain("verifying");
    expect(phases).toContain("staged");
    expect(phases).toContain("draining");
    expect(phases).toContain("applying");
    expect(phases).toContain("health_checking");
    expect(phases).toContain("completed");
  });

  it("automatically rolls back when post-update health check fails during self-update", async () => {
    // Create initial v1.2.0 in current
    const currentDir = path.join(tmpDir, "updates", "current");
    fs.mkdirSync(currentDir, { recursive: true });
    fs.writeFileSync(
      path.join(currentDir, "release.bin"),
      "v1.2.0-working-binary",
    );

    const pkg = Buffer.from("conclave-agent-v1.3.0-crashing-bundle");
    const digest = await computePackageDigest(pkg);
    const signature = await signPackageDigest(digest, signingKey);

    const release: AgentReleaseInfo = {
      version: "1.3.0",
      channel: "stable",
      supportedOS: ["macos", "linux", "windows"],
      supportedArch: ["arm64", "x64"],
      packageDigest: digest,
      packageR2Key: "agent/releases/1.3.0.tar.gz",
      signature,
    };

    updater.checkForUpdates = async () => release;
    updater.downloadRelease = async () => pkg;

    const phases: string[] = [];
    const result = await updater.performSelfUpdate({
      currentVersion: "1.2.0",
      channel: "stable",
      signingKey,
      onPhaseChange: (phase) => {
        phases.push(phase);
      },
      customHealthCheck: async () => {
        // Simulate health check failure
        return false;
      },
    });

    expect(result.success).toBe(false);
    expect(result.rolledBack).toBe(true);
    expect(result.error).toMatch(/Health check failed/i);
    expect(phases).toContain("rolled_back");

    // Verify current directory was restored to v1.2.0 working binary
    expect(fs.readFileSync(path.join(currentDir, "release.bin"), "utf8")).toBe(
      "v1.2.0-working-binary",
    );
  });
});
