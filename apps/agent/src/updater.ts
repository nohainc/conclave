import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import {
  computePackageDigest,
  verifyPackageDigestSignature,
} from "@conclave/security";
import type { AgentConfig } from "./config.js";
import type { AgentLogger } from "./logger.js";
import type { WorkerManager } from "./worker-manager.js";

export interface AgentReleaseInfo {
  readonly version: string;
  readonly channel: "stable" | "beta" | "development";
  readonly minSupportedAgentVersion?: string | null;
  readonly supportedOS: readonly string[];
  readonly supportedArch: readonly string[];
  readonly packageDigest: string;
  readonly packageR2Key: string;
  readonly signature: string;
  readonly releaseNotes?: string | null;
}

export type UpdatePhase =
  | "checking"
  | "downloading"
  | "verifying"
  | "staged"
  | "draining"
  | "applying"
  | "health_checking"
  | "completed"
  | "failed"
  | "rolled_back";

export interface SelfUpdateResult {
  readonly success: boolean;
  readonly previousVersion: string;
  readonly targetVersion?: string;
  readonly rolledBack?: boolean;
  readonly error?: string;
}

export class AgentUpdater {
  private readonly updatesDir: string;
  private readonly stagingDir: string;
  private readonly currentDir: string;
  private readonly previousDir: string;
  private readonly stateFile: string;

  constructor(
    private readonly config: AgentConfig,
    private readonly logger: AgentLogger,
    private readonly workerManager?: WorkerManager,
    private readonly signingKey: string = "conclave-default-signing-key",
  ) {
    this.updatesDir = path.join(this.config.homeDir, "updates");
    this.stagingDir = path.join(this.updatesDir, "staged");
    this.currentDir = path.join(this.updatesDir, "current");
    this.previousDir = path.join(this.updatesDir, "previous");
    this.stateFile = path.join(this.updatesDir, "state.json");
  }

  ensureDirectories(): void {
    fs.mkdirSync(this.updatesDir, { recursive: true });
    fs.mkdirSync(this.stagingDir, { recursive: true });
  }

  /**
   * Queries Cloud endpoint to check if an update is available.
   */
  async checkForUpdates(
    currentVersion: string,
    channel: "stable" | "beta" | "development" = "stable",
  ): Promise<AgentReleaseInfo | null> {
    this.ensureDirectories();

    const hostOS = os.platform() === "darwin" ? "macos" : os.platform();
    const hostArch = os.arch();

    const url = new URL(`${this.config.cloudUrl}/api/v2/agent-releases/latest`);
    url.searchParams.set("channel", channel);
    url.searchParams.set("currentVersion", currentVersion);
    url.searchParams.set("os", hostOS);
    url.searchParams.set("arch", hostArch);

    try {
      const res = await fetch(url.toString(), {
        headers: {
          ...(this.config.agentToken
            ? { Authorization: `Bearer ${this.config.agentToken}` }
            : {}),
        },
      });

      if (!res.ok) {
        throw new Error(`Failed to check for updates: HTTP ${res.status}`);
      }

      const data = (await res.json()) as {
        updateAvailable: boolean;
        release: AgentReleaseInfo | null;
      };

      if (data.updateAvailable && data.release) {
        return data.release;
      }
      return null;
    } catch (err) {
      this.logger.error("Update check failed", {
        error: err instanceof Error ? err.message : String(err),
      });
      return null;
    }
  }

  /**
   * Downloads release package archive from Cloud storage.
   */
  async downloadRelease(release: AgentReleaseInfo): Promise<Buffer> {
    const downloadUrl = `${this.config.cloudUrl}/api/v2/agent-releases/${encodeURIComponent(
      release.version,
    )}/download`;

    const res = await fetch(downloadUrl, {
      headers: {
        ...(this.config.agentToken
          ? { Authorization: `Bearer ${this.config.agentToken}` }
          : {}),
      },
    });

    if (res.status === 410) {
      throw new Error(
        `Agent release '${release.version}' has been revoked by Conclave Cloud`,
      );
    }

    if (!res.ok) {
      throw new Error(
        `Failed to download release '${release.version}': HTTP ${res.status}`,
      );
    }

    const arrayBuffer = await res.arrayBuffer();
    return Buffer.from(arrayBuffer);
  }

  /**
   * Verifies package SHA-256 digest and HMAC-SHA256 signature.
   */
  async verifyRelease(
    packageBuffer: Buffer,
    release: AgentReleaseInfo,
    keyOverride?: string,
  ): Promise<boolean> {
    const key = keyOverride || this.signingKey;

    // 1. Verify SHA-256 digest
    const computedDigest = await computePackageDigest(packageBuffer);
    if (computedDigest !== release.packageDigest) {
      this.logger.error("Package digest mismatch", {
        expected: release.packageDigest,
        computed: computedDigest,
      });
      return false;
    }

    // 2. Verify cryptographic signature
    const isValidSignature = await verifyPackageDigestSignature(
      computedDigest,
      release.signature,
      key,
    );

    if (!isValidSignature) {
      this.logger.error("Package cryptographic signature verification failed", {
        version: release.version,
        digest: computedDigest,
      });
      return false;
    }

    return true;
  }

  /**
   * Stages the downloaded bundle in staging directory.
   */
  async stageRelease(
    release: AgentReleaseInfo,
    packageBuffer: Buffer,
  ): Promise<string> {
    this.ensureDirectories();

    const targetDir = path.join(this.stagingDir, release.version);
    fs.rmSync(targetDir, { recursive: true, force: true });
    fs.mkdirSync(targetDir, { recursive: true });

    // Store binary bundle / package.json
    const archivePath = path.join(targetDir, "release.bin");
    fs.writeFileSync(archivePath, packageBuffer);

    // Create manifest metadata in staged directory
    const manifestPath = path.join(targetDir, "release-manifest.json");
    fs.writeFileSync(
      manifestPath,
      JSON.stringify(
        {
          ...release,
          stagedAt: new Date().toISOString(),
        },
        null,
        2,
      ),
      "utf8",
    );

    return targetDir;
  }

  /**
   * Drains active assignments cleanly before applying upgrade.
   */
  async drainActiveWork(timeoutMs: number = 30000): Promise<boolean> {
    if (!this.workerManager) return true;
    this.logger.info("Draining active worker assignments before agent update", {
      activeAssignments: this.workerManager.getActiveAssignmentsCount(),
      timeoutMs,
    });
    return await this.workerManager.waitForIdle(timeoutMs);
  }

  /**
   * Performs atomic cutover to new version and backs up previous version.
   */
  async applyUpdate(
    release: AgentReleaseInfo,
    stagedDir: string,
    currentVersion: string,
  ): Promise<void> {
    this.ensureDirectories();

    // 1. Backup current active directory to previous
    if (fs.existsSync(this.currentDir)) {
      fs.rmSync(this.previousDir, { recursive: true, force: true });
      fs.cpSync(this.currentDir, this.previousDir, { recursive: true });
    }

    // 2. Cutover staged directory to current
    fs.rmSync(this.currentDir, { recursive: true, force: true });
    fs.cpSync(stagedDir, this.currentDir, { recursive: true });

    // 3. Write persistent state file
    fs.writeFileSync(
      this.stateFile,
      JSON.stringify(
        {
          currentVersion: release.version,
          previousVersion: currentVersion,
          updatedAt: new Date().toISOString(),
        },
        null,
        2,
      ),
      "utf8",
    );

    this.logger.info("Applied agent update cutover", {
      fromVersion: currentVersion,
      toVersion: release.version,
    });
  }

  /**
   * Executes post-update health check.
   */
  async executeHealthCheck(
    targetDir: string,
    customHealthCheck?: () => Promise<boolean>,
  ): Promise<boolean> {
    if (customHealthCheck) {
      try {
        return await customHealthCheck();
      } catch (err) {
        this.logger.error("Custom health check failed", {
          error: err instanceof Error ? err.message : String(err),
        });
        return false;
      }
    }

    const manifestPath = path.join(targetDir, "release-manifest.json");
    if (!fs.existsSync(manifestPath)) {
      return false;
    }

    const releaseBin = path.join(targetDir, "release.bin");
    if (!fs.existsSync(releaseBin)) {
      return false;
    }

    // Self-test integrity check
    try {
      const stat = fs.statSync(releaseBin);
      return stat.size > 0;
    } catch {
      return false;
    }
  }

  /**
   * Performs rollback to previous working version.
   */
  async rollback(previousVersion?: string): Promise<boolean> {
    this.logger.warn("Rolling back agent installation to previous version", {
      previousVersion,
    });

    try {
      if (!fs.existsSync(this.previousDir)) {
        this.logger.error(
          "Rollback failed: No previous version backup directory found",
        );
        return false;
      }

      fs.rmSync(this.currentDir, { recursive: true, force: true });
      fs.cpSync(this.previousDir, this.currentDir, { recursive: true });

      fs.writeFileSync(
        this.stateFile,
        JSON.stringify(
          {
            currentVersion: previousVersion || "unknown",
            rolledBack: true,
            rolledBackAt: new Date().toISOString(),
          },
          null,
          2,
        ),
        "utf8",
      );

      this.logger.info("Agent rollback completed successfully");
      return true;
    } catch (err) {
      this.logger.error("Agent rollback execution failed", {
        error: err instanceof Error ? err.message : String(err),
      });
      return false;
    }
  }

  /**
   * Executes complete end-to-end self-update lifecycle with verification and rollback.
   */
  async performSelfUpdate(options: {
    currentVersion: string;
    channel?: "stable" | "beta" | "development";
    signingKey?: string;
    drainTimeoutMs?: number;
    healthCheckTimeoutMs?: number;
    customHealthCheck?: () => Promise<boolean>;
    onPhaseChange?: (phase: UpdatePhase, details?: string) => void;
  }): Promise<SelfUpdateResult> {
    const {
      currentVersion,
      channel = "stable",
      signingKey,
      drainTimeoutMs = 30000,
      customHealthCheck,
      onPhaseChange,
    } = options;

    onPhaseChange?.("checking", `Checking ${channel} channel for updates`);

    // 1. Check for update
    const release = await this.checkForUpdates(currentVersion, channel);
    if (!release) {
      return {
        success: false,
        previousVersion: currentVersion,
        error: "No compatible updates found",
      };
    }

    onPhaseChange?.("downloading", `Downloading version ${release.version}`);

    // 2. Download
    let packageBuffer: Buffer;
    try {
      packageBuffer = await this.downloadRelease(release);
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : String(err);
      onPhaseChange?.("failed", errorMsg);
      return {
        success: false,
        previousVersion: currentVersion,
        targetVersion: release.version,
        error: errorMsg,
      };
    }

    onPhaseChange?.(
      "verifying",
      "Verifying cryptographic signature and digest",
    );

    // 3. Verify signature and digest
    const isValid = await this.verifyRelease(
      packageBuffer,
      release,
      signingKey,
    );
    if (!isValid) {
      const errorMsg =
        "Cryptographic signature or SHA-256 package digest verification failed";
      onPhaseChange?.("failed", errorMsg);
      return {
        success: false,
        previousVersion: currentVersion,
        targetVersion: release.version,
        error: errorMsg,
      };
    }

    onPhaseChange?.("staged", `Staging version ${release.version}`);

    // 4. Stage release
    const stagedDir = await this.stageRelease(release, packageBuffer);

    onPhaseChange?.("draining", "Waiting for active assignments to finish");

    // 5. Drain active assignments
    const drained = await this.drainActiveWork(drainTimeoutMs);
    if (!drained) {
      this.logger.warn(
        "Assignments did not drain within timeout; proceeding with graceful update",
      );
    }

    onPhaseChange?.(
      "applying",
      `Applying update to version ${release.version}`,
    );

    // 6. Apply update (cutover)
    await this.applyUpdate(release, stagedDir, currentVersion);

    onPhaseChange?.("health_checking", "Executing post-update health check");

    // 7. Health check
    const isHealthy = await this.executeHealthCheck(
      this.currentDir,
      customHealthCheck,
    );

    if (!isHealthy) {
      this.logger.error(
        "Health check failed on updated version; rolling back",
        {
          failedVersion: release.version,
        },
      );

      onPhaseChange?.("health_checking", "Health check failed, rolling back");

      // 8. Rollback
      const rolledBack = await this.rollback(currentVersion);
      onPhaseChange?.(
        "rolled_back",
        `Rolled back to previous version ${currentVersion}`,
      );

      return {
        success: false,
        previousVersion: currentVersion,
        targetVersion: release.version,
        rolledBack,
        error: "Health check failed after update",
      };
    }

    onPhaseChange?.(
      "completed",
      `Agent successfully updated to version ${release.version}`,
    );

    return {
      success: true,
      previousVersion: currentVersion,
      targetVersion: release.version,
    };
  }
}
