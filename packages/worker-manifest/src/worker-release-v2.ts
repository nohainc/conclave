import { z } from "zod";

const nonEmpty = z.string().trim().min(1);
const semver = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;
const protocolVersion = /^(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const digest = /^[a-f0-9]{64}$/;
const identifier = /^[a-z][a-z0-9:_-]*$/;

export const WorkerReleasePlatformSchema = z.enum([
  "macos-arm64",
  "macos-x64",
  "linux-arm64",
  "linux-x64",
  "windows-arm64",
  "windows-x64",
]);

export const WorkerReleaseManifestV2Schema = z
  .object({
    manifestVersion: z.literal(2),
    workerTypeId: nonEmpty.regex(/^[a-z0-9][a-z0-9._-]*$/),
    workerVersion: nonEmpty.regex(semver),
    publisher: nonEmpty.max(256),
    platform: WorkerReleasePlatformSchema,
    protocol: z
      .object({
        min: nonEmpty.regex(protocolVersion),
        max: nonEmpty.regex(protocolVersion),
      })
      .strict(),
    stateSchema: z
      .object({
        readMin: z.number().int().positive(),
        readMax: z.number().int().positive(),
        write: z.number().int().positive(),
      })
      .strict(),
    capabilities: z.array(nonEmpty.max(128).regex(identifier)).max(128),
    permissions: z.array(nonEmpty.max(128).regex(identifier)).max(64),
    executable: nonEmpty.max(512),
    releaseChannel: z.enum(["stable", "beta", "development"]),
    packageDigest: nonEmpty.regex(digest),
    archiveSha256: nonEmpty.regex(digest),
    signingKeyId: nonEmpty.regex(/^[A-Za-z0-9._-]{1,64}$/),
    signature: nonEmpty.max(256),
  })
  .strict()
  .superRefine((manifest, ctx) => {
    const versionParts = (value: string) => value.split(".").map(Number);
    const min = versionParts(manifest.protocol.min);
    const max = versionParts(manifest.protocol.max);
    if (min[0]! > max[0]! || (min[0] === max[0] && min[1]! > max[1]!)) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["protocol"],
        message: "Minimum protocol version must not exceed maximum",
      });
    }
    const { readMin, readMax, write } = manifest.stateSchema;
    if (readMin > readMax || write < readMin || write > readMax) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["stateSchema"],
        message: "Worker state schema range is inconsistent",
      });
    }
    for (const [field, values] of Object.entries({
      capabilities: manifest.capabilities,
      permissions: manifest.permissions,
    })) {
      if (new Set(values).size !== values.length) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: [field],
          message: `${field} must not contain duplicates`,
        });
      }
    }
    if (!isWorkerPackageRelativePath(manifest.executable)) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["executable"],
        message: "Worker executable must stay inside its verified package",
      });
    }
  });

export type WorkerReleaseManifestV2 = z.infer<
  typeof WorkerReleaseManifestV2Schema
>;

export function isWorkerPackageRelativePath(value: string): boolean {
  if (
    !value ||
    value.includes("\\") ||
    value.includes("\0") ||
    value.startsWith("/") ||
    /^[A-Za-z]:/.test(value)
  ) {
    return false;
  }
  return value
    .split("/")
    .every((part) => part.length > 0 && part !== "." && part !== "..");
}

export function parseWorkerReleaseManifestV2(
  input: unknown,
): WorkerReleaseManifestV2 {
  return WorkerReleaseManifestV2Schema.parse(input);
}
