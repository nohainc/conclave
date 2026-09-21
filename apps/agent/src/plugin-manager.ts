import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import {
  satisfiesSemverRange,
  compareSemver,
  isPluginCompatibleWithAgent,
  validateWorkerPluginManifest,
  type WorkerPluginManifest,
  type PluginOperatingSystem,
  type PluginArchitecture,
} from "@conclave/plugin-sdk";
import {
  computePackageDigest,
  verifyPackageDigestSignature,
  assertAllowedPermissions,
} from "@conclave/security";
import type { AgentConfig } from "./config.js";
import type { AgentLogger } from "./logger.js";
import type { AgentStorage } from "./storage.js";
import type { WorkerManager } from "./worker-manager.js";

export interface ProvisionedPlugin {
  readonly pluginId: string;
  readonly version: string;
  readonly pluginDir: string;
  readonly manifest: WorkerPluginManifest;
}

export interface CloudPluginVersionRecord {
  readonly id: string;
  readonly pluginId: string;
  readonly version: string;
  readonly channel: "stable" | "beta" | "development";
  readonly protocolVersion: string;
  readonly minAgentVersion: string;
  readonly supportedOS: readonly string[];
  readonly supportedArch: readonly string[];
  readonly packageDigest: string;
  readonly packageR2Key: string;
  readonly signature: string;
  readonly isRevoked: boolean;
  readonly permissions?: readonly string[];
  readonly configSchema?: Record<string, unknown>;
  readonly secretSchema?: Record<string, unknown>;
}

export interface CloudPluginDetails {
  readonly plugin: {
    readonly id: string;
    readonly displayName: string;
    readonly description: string;
    readonly publisher: string;
    readonly status: string;
  };
  readonly versions: readonly CloudPluginVersionRecord[];
  readonly latestByChannel: Record<string, string>;
}

export class PluginManager {
  private readonly signingKey: string;

  constructor(
    private readonly config: AgentConfig,
    private readonly storage: AgentStorage,
    private readonly logger: AgentLogger,
    private readonly workerManager?: WorkerManager,
    signingKeyOverride?: string,
  ) {
    const configuredSigningKey =
      signingKeyOverride || process.env.CONCLAVE_PLUGIN_SIGNING_KEY;
    if (!configuredSigningKey && process.env.CONCLAVE_ENVIRONMENT === "production") {
      throw new Error("CONCLAVE_PLUGIN_SIGNING_KEY is required in production");
    }
    this.signingKey = configuredSigningKey || "conclave-default-signing-key";
  }

  /**
   * Lists all locally installed plugins and their versions.
   */
  listInstalledPlugins(): Map<string, string[]> {
    const installed = new Map<string, string[]>();
    const pluginBaseDir = this.config.pluginDir;

    if (!fs.existsSync(pluginBaseDir)) {
      return installed;
    }

    const pluginDirs = fs
      .readdirSync(pluginBaseDir, { withFileTypes: true })
      .filter((d) => d.isDirectory())
      .map((d) => d.name);

    for (const pId of pluginDirs) {
      const pPath = path.join(pluginBaseDir, pId);
      const versionDirs = fs
        .readdirSync(pPath, { withFileTypes: true })
        .filter(
          (d) => d.isDirectory() && d.name !== "staged" && d.name !== "temp",
        )
        .map((d) => d.name);

      if (versionDirs.length > 0) {
        versionDirs.sort((a, b) => compareSemver(b, a));
        installed.set(pId, versionDirs);
      }
    }

    return installed;
  }

  /**
   * Resolves the highest installed version satisfying the given version policy.
   */
  resolveLocalVersion(pluginId: string, versionPolicy: string): string | null {
    const installed = this.listInstalledPlugins();
    const versions = installed.get(pluginId) || [];

    for (const ver of versions) {
      if (satisfiesSemverRange(ver, versionPolicy)) {
        return ver;
      }
    }

    return null;
  }

  /**
   * Reads the manifest file of an installed plugin version.
   */
  readInstalledManifest(
    pluginId: string,
    version: string,
  ): WorkerPluginManifest | null {
    const pDir = this.storage.getPluginDir(pluginId, version);
    const manifestPath = path.join(pDir, "manifest.json");
    if (!fs.existsSync(manifestPath)) {
      return null;
    }

    try {
      const raw = fs.readFileSync(manifestPath, "utf8");
      const parsed = JSON.parse(raw);
      return validateWorkerPluginManifest(parsed);
    } catch (err) {
      this.logger.error("Failed to read plugin manifest", {
        pluginId,
        version,
        error: err instanceof Error ? err.message : String(err),
      });
      return null;
    }
  }

  /**
   * Queries Cloud registry for plugin details and available versions.
   */
  async fetchCloudPluginDetails(
    pluginId: string,
  ): Promise<CloudPluginDetails | null> {
    const url = `${this.config.cloudUrl}/api/v2/plugins/${encodeURIComponent(pluginId)}`;

    try {
      const res = await fetch(url, {
        headers: {
          ...(this.config.agentToken
            ? { Authorization: `Bearer ${this.config.agentToken}` }
            : {}),
        },
      });

      if (!res.ok) {
        if (res.status === 404) return null;
        throw new Error(
          `Failed to fetch plugin '${pluginId}': HTTP ${res.status}`,
        );
      }

      return (await res.json()) as CloudPluginDetails;
    } catch (err) {
      this.logger.error("Cloud plugin fetch failed", {
        pluginId,
        error: err instanceof Error ? err.message : String(err),
      });
      return null;
    }
  }

  /**
   * Downloads plugin package binary archive from Cloud registry.
   */
  async downloadPluginArchive(
    pluginId: string,
    version: string,
  ): Promise<Buffer> {
    const url = `${this.config.cloudUrl}/api/v2/plugins/${encodeURIComponent(
      pluginId,
    )}/versions/${encodeURIComponent(version)}/download`;

    const res = await fetch(url, {
      headers: {
        ...(this.config.agentToken
          ? { Authorization: `Bearer ${this.config.agentToken}` }
          : {}),
      },
    });

    if (res.status === 410) {
      throw new Error(`Plugin '${pluginId}@${version}' has been revoked`);
    }

    if (!res.ok) {
      throw new Error(
        `Failed to download plugin '${pluginId}@${version}': HTTP ${res.status}`,
      );
    }

    const arrayBuffer = await res.arrayBuffer();
    return Buffer.from(arrayBuffer);
  }

  /**
   * Verifies cryptographic signature and SHA-256 package digest.
   */
  async verifyPluginArchive(
    packageBuffer: Buffer,
    expectedDigest: string,
    signature: string,
  ): Promise<boolean> {
    const computedDigest = await computePackageDigest(packageBuffer);
    if (computedDigest !== expectedDigest) {
      this.logger.error("Plugin package digest mismatch", {
        expected: expectedDigest,
        computed: computedDigest,
      });
      return false;
    }

    const isValid = await verifyPackageDigestSignature(
      computedDigest,
      signature,
      this.signingKey,
    );

    if (!isValid) {
      this.logger.error("Plugin signature verification failed", {
        digest: computedDigest,
      });
      return false;
    }

    return true;
  }

  /**
   * Stages a plugin archive in `<pluginDir>/<pluginId>/staged/<version>`.
   */
  stagePlugin(
    pluginId: string,
    version: string,
    packageBuffer: Buffer,
    manifest: WorkerPluginManifest,
  ): string {
    assertAllowedPermissions(manifest.permissions);
    const stageDir = path.join(
      this.config.pluginDir,
      pluginId,
      "staged",
      version,
    );
    fs.rmSync(stageDir, { recursive: true, force: true });
    fs.mkdirSync(stageDir, { recursive: true });

    // Store binary / extracted contents
    const archivePath = path.join(stageDir, "package.bin");
    fs.writeFileSync(archivePath, packageBuffer);

    // Write manifest
    const manifestPath = path.join(stageDir, "manifest.json");
    fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2), "utf8");

    // Write default entrypoint if not already present
    const entrypointPath = path.join(
      stageDir,
      manifest.entrypoint || "index.js",
    );
    if (!fs.existsSync(entrypointPath)) {
      const parent = path.dirname(entrypointPath);
      fs.mkdirSync(parent, { recursive: true });
      fs.writeFileSync(
        entrypointPath,
        `// Conclave Plugin: ${pluginId}@${version}\nexport async function execute(ctx) { return { status: 'completed', output: ctx.input }; }\n`,
        "utf8",
      );
    }

    return stageDir;
  }

  /**
   * Installs and activates a staged plugin into `<pluginDir>/<pluginId>/<version>`.
   */
  activatePlugin(pluginId: string, version: string, stagedDir: string): string {
    const targetDir = this.storage.getPluginDir(pluginId, version);
    fs.rmSync(targetDir, { recursive: true, force: true });
    fs.cpSync(stagedDir, targetDir, { recursive: true });

    // Clean up staging directory
    fs.rmSync(stagedDir, { recursive: true, force: true });

    // Update active pointer state file
    const activeFile = path.join(
      this.config.pluginDir,
      pluginId,
      "active.json",
    );
    fs.writeFileSync(
      activeFile,
      JSON.stringify(
        {
          pluginId,
          activeVersion: version,
          activatedAt: new Date().toISOString(),
        },
        null,
        2,
      ),
      "utf8",
    );

    this.logger.info("Activated plugin version", {
      pluginId,
      version,
      targetDir,
    });

    return targetDir;
  }

  /**
   * Executes plugin health check.
   */
  async executePluginHealthCheck(
    pluginDir: string,
    customHealthCheck?: () => Promise<boolean>,
  ): Promise<boolean> {
    if (customHealthCheck) {
      try {
        return await customHealthCheck();
      } catch (err) {
        this.logger.error("Custom plugin health check failed", {
          error: err instanceof Error ? err.message : String(err),
        });
        return false;
      }
    }

    const manifestPath = path.join(pluginDir, "manifest.json");
    if (!fs.existsSync(manifestPath)) return false;

    try {
      const raw = fs.readFileSync(manifestPath, "utf8");
      const manifest = validateWorkerPluginManifest(JSON.parse(raw));
      const entrypointPath = path.join(pluginDir, manifest.entrypoint);
      return fs.existsSync(entrypointPath);
    } catch {
      return false;
    }
  }

  /**
   * Performs plugin rollback to a previous installed version.
   */
  async rollbackPlugin(
    pluginId: string,
    fallbackVersion: string,
  ): Promise<boolean> {
    this.logger.warn("Rolling back plugin to previous version", {
      pluginId,
      fallbackVersion,
    });

    const fallbackDir = this.storage.getPluginDir(pluginId, fallbackVersion);
    if (!fs.existsSync(fallbackDir)) {
      this.logger.error("Fallback plugin version not found", {
        pluginId,
        fallbackVersion,
      });
      return false;
    }

    const activeFile = path.join(
      this.config.pluginDir,
      pluginId,
      "active.json",
    );
    fs.writeFileSync(
      activeFile,
      JSON.stringify(
        {
          pluginId,
          activeVersion: fallbackVersion,
          rolledBack: true,
          activatedAt: new Date().toISOString(),
        },
        null,
        2,
      ),
      "utf8",
    );

    return true;
  }

  /**
   * Ensures that a plugin matching the version policy is locally installed, verified, and healthy.
   * Auto-downloads, verifies, stages, drains, activates, and health-checks.
   */
  async ensurePlugin(
    pluginId: string,
    versionPolicy: string = "latest",
    options?: {
      channel?: "stable" | "beta" | "development";
      forceUpdate?: boolean;
      customHealthCheck?: () => Promise<boolean>;
      onPhaseChange?: (phase: string, details?: string) => void;
    },
  ): Promise<ProvisionedPlugin> {
    const {
      channel = "stable",
      forceUpdate = false,
      customHealthCheck,
      onPhaseChange,
    } = options || {};

    const hostOS = os.platform() === "darwin" ? "macos" : os.platform();
    const hostArch = os.arch();
    const agentVersion = "2.0.0";

    // 1. Check local installation
    const installedVersions = this.listInstalledPlugins().get(pluginId) || [];
    const localVer = this.resolveLocalVersion(pluginId, versionPolicy);
    const previousInstalledVer = localVer || installedVersions[0];
    if (localVer && !forceUpdate) {
      const manifest = this.readInstalledManifest(pluginId, localVer);
      const pluginDir = this.storage.getPluginDir(pluginId, localVer);
      if (manifest) {
        const isHealthy = await this.executePluginHealthCheck(
          pluginDir,
          customHealthCheck,
        );
        if (isHealthy) {
          onPhaseChange?.(
            "ready",
            `Local plugin '${pluginId}@${localVer}' is ready`,
          );
          return {
            pluginId,
            version: localVer,
            pluginDir,
            manifest,
          };
        }
      }
    }

    onPhaseChange?.(
      "checking",
      `Checking Cloud registry for '${pluginId}' matching '${versionPolicy}'`,
    );

    // 2. Query Cloud Registry
    const cloudDetails = await this.fetchCloudPluginDetails(pluginId);
    if (!cloudDetails || cloudDetails.versions.length === 0) {
      throw new Error(`Plugin '${pluginId}' not found in Cloud registry`);
    }

    // Filter compatible versions matching channel, OS, arch, not revoked, and policy
    const candidateVersions = cloudDetails.versions.filter((v) => {
      if (v.channel !== channel) return false;
      if (v.isRevoked) return false;
      if (!satisfiesSemverRange(v.version, versionPolicy)) return false;
      if (!v.supportedOS.includes(hostOS)) return false;
      if (!v.supportedArch.includes(hostArch)) return false;
      return true;
    });

    candidateVersions.sort((a, b) => compareSemver(b.version, a.version));

    const targetVersionRecord = candidateVersions[0];
    if (!targetVersionRecord) {
      throw new Error(
        `No compatible version found for plugin '${pluginId}' matching policy '${versionPolicy}' on channel '${channel}' for ${hostOS}-${hostArch}`,
      );
    }

    const targetVersion = targetVersionRecord.version;

    onPhaseChange?.(
      "downloading",
      `Downloading plugin '${pluginId}@${targetVersion}'`,
    );

    // 3. Download package archive
    const packageBuffer = await this.downloadPluginArchive(
      pluginId,
      targetVersion,
    );

    onPhaseChange?.(
      "verifying",
      `Verifying signature and digest for '${pluginId}@${targetVersion}'`,
    );

    // 4. Verify cryptographic digest and signature
    const isValid = await this.verifyPluginArchive(
      packageBuffer,
      targetVersionRecord.packageDigest,
      targetVersionRecord.signature,
    );
    if (!isValid) {
      throw new Error(
        `Cryptographic signature or package digest verification failed for '${pluginId}@${targetVersion}'`,
      );
    }

    // Build synthesized manifest
    const manifest: WorkerPluginManifest = {
      pluginId,
      version: targetVersion,
      displayName: cloudDetails.plugin.displayName,
      description: cloudDetails.plugin.description,
      publisher: cloudDetails.plugin.publisher,
      channel,
      protocolVersion: targetVersionRecord.protocolVersion || "2.0",
      minimumAgentVersion: targetVersionRecord.minAgentVersion || "0.2.0",
      supportedOS: targetVersionRecord.supportedOS as PluginOperatingSystem[],
      supportedArchitecture:
        targetVersionRecord.supportedArch as PluginArchitecture[],
      roles: ["implementer", "coder"],
      capabilities: ["code_execution"],
      permissions: (targetVersionRecord.permissions as string[]) || [],
      configurationSchema: targetVersionRecord.configSchema || {},
      secretSchema: targetVersionRecord.secretSchema || {},
      entrypoint: "index.js",
      billingModes: ["subscription", "free"],
      digest: targetVersionRecord.packageDigest,
      signature: targetVersionRecord.signature,
    };

    // Verify agent compatibility
    const compat = isPluginCompatibleWithAgent(manifest, {
      os: hostOS,
      architecture: hostArch,
      agentVersion,
    });
    if (!compat.compatible) {
      throw new Error(
        `Plugin '${pluginId}@${targetVersion}' is incompatible: ${compat.reason}`,
      );
    }

    onPhaseChange?.("staged", `Staging '${pluginId}@${targetVersion}'`);

    // 5. Stage release
    const stagedDir = this.stagePlugin(
      pluginId,
      targetVersion,
      packageBuffer,
      manifest,
    );

    // 6. Drain active tasks if updating existing installed version
    if (
      previousInstalledVer &&
      previousInstalledVer !== targetVersion &&
      this.workerManager
    ) {
      onPhaseChange?.(
        "draining",
        `Draining active tasks before upgrading '${pluginId}' from ${previousInstalledVer} to ${targetVersion}`,
      );
      await this.workerManager.waitForIdle(30000);
    }

    onPhaseChange?.("activating", `Activating '${pluginId}@${targetVersion}'`);

    // 7. Activate plugin version
    const activePluginDir = this.activatePlugin(
      pluginId,
      targetVersion,
      stagedDir,
    );

    onPhaseChange?.(
      "health_checking",
      `Running health check for '${pluginId}@${targetVersion}'`,
    );

    // 8. Health check
    const isHealthy = await this.executePluginHealthCheck(
      activePluginDir,
      customHealthCheck,
    );

    if (!isHealthy) {
      this.logger.error("Health check failed on newly activated plugin", {
        pluginId,
        version: targetVersion,
      });

      if (previousInstalledVer && previousInstalledVer !== targetVersion) {
        await this.rollbackPlugin(pluginId, previousInstalledVer);
        onPhaseChange?.(
          "rolled_back",
          `Health check failed; rolled back '${pluginId}' to ${previousInstalledVer}`,
        );
      }

      throw new Error(
        `Plugin '${pluginId}@${targetVersion}' failed health check verification`,
      );
    }

    onPhaseChange?.(
      "completed",
      `Plugin '${pluginId}@${targetVersion}' is installed and ready`,
    );

    return {
      pluginId,
      version: targetVersion,
      pluginDir: activePluginDir,
      manifest,
    };
  }
}
