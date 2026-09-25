export interface WorkspaceReleaseTarget {
  readonly platform: "macos" | "windows" | "linux";
  readonly label: string;
  readonly architectures: readonly string[];
  readonly downloadUrl: string;
}

export interface WorkspaceReleaseManifest {
  readonly productName: string;
  readonly version: string;
  readonly targets: readonly WorkspaceReleaseTarget[];
}

/**
 * Static distribution metadata. Keep installer URLs here so product surfaces
 * consume one release manifest instead of carrying independent links.
 */
export const workspaceRelease: WorkspaceReleaseManifest = {
  productName: "Conclave Workspace",
  version: "1.0.3",
  targets: [
    {
      platform: "macos",
      label: "macOS",
      architectures: ["Apple Silicon", "Intel"],
      downloadUrl: "https://github.com/nohainc/conclave/releases/latest",
    },
    {
      platform: "windows",
      label: "Windows",
      architectures: ["x64"],
      downloadUrl: "https://github.com/nohainc/conclave/releases/latest",
    },
    {
      platform: "linux",
      label: "Linux",
      architectures: ["x64"],
      downloadUrl: "https://github.com/nohainc/conclave/releases/latest",
    },
  ],
};
