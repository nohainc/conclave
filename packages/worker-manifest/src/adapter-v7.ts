import { z } from "zod";

const nonEmpty = z.string().trim().min(1);
const semver = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;
const slug = /^[a-z0-9][a-z0-9._-]*$/;

export const V7AdapterPlatformSchema = z.enum([
  "macos-arm64",
  "macos-x64",
  "linux-arm64",
  "linux-x64",
  "windows-arm64",
  "windows-x64",
]);

export const V7AdapterAuthStrategySchema = z.enum([
  "none",
  "browser_auth",
  "api_key",
  "local_endpoint",
]);

export const V7AdapterPrerequisiteSchema = z
  .object({
    kind: z.literal("executable"),
    executable: nonEmpty.regex(/^[A-Za-z0-9][A-Za-z0-9._+-]*$/, {
      message: "Prerequisite executable must be a command name, not a path",
    }),
    minimumVersion: nonEmpty.regex(semver).optional(),
    maximumVersion: nonEmpty.regex(semver).optional(),
    versionArgs: z.array(z.string().max(256)).max(16).default(["--version"]),
    installHelpUrl: z.string().url().optional(),
    installHelpMessage: z.string().max(512).optional(),
  })
  .strict();

export const V7AdapterSecretRequirementSchema = z
  .object({
    name: nonEmpty.regex(slug),
    authStrategy: V7AdapterAuthStrategySchema,
    environmentVariable: nonEmpty.regex(/^[A-Z_][A-Z0-9_]*$/),
    required: z.boolean().default(true),
    description: z.string().max(512).default(""),
  })
  .strict();

export const V7AdapterManifestSchema = z
  .object({
    workerTypeId: nonEmpty.regex(slug),
    adapterVersion: nonEmpty.regex(semver),
    protocolVersion: nonEmpty.regex(/^\d+\.\d+$/),
    publisher: nonEmpty,
    displayName: nonEmpty,
    supportedPlatforms: z.array(V7AdapterPlatformSchema).min(1).max(6),
    capabilities: z.array(nonEmpty).max(128),
    permissions: z.array(nonEmpty).max(64),
    authStrategies: z.array(V7AdapterAuthStrategySchema).min(1).max(4),
    modelSelectionMode: z.enum(["fixed", "allow_list", "automatic"]),
    prerequisites: z.array(V7AdapterPrerequisiteSchema).max(32).default([]),
    executable: nonEmpty,
    launchArgs: z.array(z.string().max(2048)).max(64).default([]),
    secretRequirements: z
      .array(V7AdapterSecretRequirementSchema)
      .max(32)
      .default([]),
    healthCheck: z
      .object({
        mode: z.enum(["protocol", "process_exit"]),
        timeoutMs: z.number().int().min(100).max(30_000).default(5_000),
      })
      .strict(),
    packageDigest: nonEmpty.regex(/^[a-f0-9]{64}$/i),
    signingKeyId: nonEmpty.regex(/^[A-Za-z0-9._-]{1,64}$/),
    signature: nonEmpty,
    releaseChannel: z.enum(["stable", "beta", "development"]),
  })
  .strict()
  .superRefine((manifest, ctx) => {
    const modelType =
      /^(?:gpt[- ]?\d|gemini[- ]?(?:pro|flash)|claude[- ]?(?:sonnet|opus|haiku))(?:$|[- .])/i;
    if (
      modelType.test(manifest.workerTypeId) ||
      modelType.test(manifest.displayName)
    ) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["workerTypeId"],
        message: "Worker Type identifies an integration, not a model",
      });
    }
    if (!isPackageRelativePath(manifest.executable)) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["executable"],
        message: "Adapter executable must stay inside its verified package",
      });
    }
    for (const secret of manifest.secretRequirements) {
      if (!manifest.authStrategies.includes(secret.authStrategy)) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ["secretRequirements"],
          message: `Secret '${secret.name}' uses an unsupported auth strategy`,
        });
      }
    }
  });

export type V7AdapterManifest = z.infer<typeof V7AdapterManifestSchema>;

export function isPackageRelativePath(value: string): boolean {
  if (
    !value ||
    value.includes("\\") ||
    value.startsWith("/") ||
    /^[A-Za-z]:/.test(value)
  ) {
    return false;
  }
  if (
    value.includes("\0") ||
    value
      .split("/")
      .some((part) => part === ".." || part === "." || part === "")
  ) {
    return false;
  }
  return true;
}

export function parseV7AdapterManifest(input: unknown): V7AdapterManifest {
  return V7AdapterManifestSchema.parse(input);
}

export const V7_ADAPTER_PROTOCOL_VERSION = "1.0" as const;
export const V7_ADAPTER_MAX_FRAME_BYTES = 1_048_576;

const requestId = nonEmpty.max(128);
const assignmentId = nonEmpty.max(128);
const message = nonEmpty.max(16_384);
const adapterCapabilities = z.array(nonEmpty.max(128)).max(128);
const issues = z
  .array(z.object({ code: nonEmpty.max(128), message }).strict())
  .max(128);

const requestBase = z.object({
  type: z.string(),
  protocolVersion: z.literal(V7_ADAPTER_PROTOCOL_VERSION),
});

export const V7AdapterMessageSchema = z.discriminatedUnion("type", [
  requestBase
    .extend({
      type: z.literal("initialize.request"),
      requestId,
      workerTypeId: nonEmpty,
      adapterVersion: nonEmpty,
    })
    .strict(),
  requestBase
    .extend({
      type: z.literal("initialize.result"),
      requestId,
      adapterVersion: nonEmpty,
      capabilities: adapterCapabilities,
    })
    .strict(),
  requestBase
    .extend({
      type: z.literal("validate.request"),
      requestId,
      config: z.record(
        z.string(),
        z.union([z.string().max(4096), z.number(), z.boolean(), z.null()]),
      ),
    })
    .strict(),
  requestBase
    .extend({
      type: z.literal("validate.result"),
      requestId,
      ready: z.boolean(),
      issues,
    })
    .strict(),
  requestBase
    .extend({
      type: z.literal("execute.request"),
      requestId,
      assignmentId,
      prompt: z.string().max(512_000),
      model: nonEmpty.max(256).optional(),
    })
    .strict(),
  requestBase
    .extend({
      type: z.literal("progress"),
      requestId,
      assignmentId,
      message,
      percentage: z.number().min(0).max(100).optional(),
    })
    .strict(),
  requestBase
    .extend({
      type: z.literal("result"),
      requestId,
      assignmentId,
      output: z.string().max(512_000),
      artifacts: z
        .array(
          z
            .object({
              name: nonEmpty.max(256),
              mediaType: nonEmpty.max(128),
              content: z.string().max(256_000),
            })
            .strict(),
        )
        .max(128)
        .default([]),
    })
    .strict(),
  requestBase
    .extend({
      type: z.literal("error"),
      requestId,
      assignmentId: assignmentId.optional(),
      code: nonEmpty.max(128),
      message,
      retryable: z.boolean().default(false),
    })
    .strict(),
  requestBase.extend({ type: z.literal("health.request"), requestId }).strict(),
  requestBase
    .extend({
      type: z.literal("health.result"),
      requestId,
      healthy: z.boolean(),
      message: z.string().max(2048).optional(),
    })
    .strict(),
  requestBase
    .extend({ type: z.literal("version.request"), requestId })
    .strict(),
  requestBase
    .extend({
      type: z.literal("version.result"),
      requestId,
      adapterVersion: nonEmpty,
      protocolVersion: nonEmpty,
    })
    .strict(),
]);

export type V7AdapterMessage = z.infer<typeof V7AdapterMessageSchema>;

export function parseV7AdapterFrame(frame: string): V7AdapterMessage {
  if (new TextEncoder().encode(frame).byteLength > V7_ADAPTER_MAX_FRAME_BYTES) {
    throw new RangeError("Adapter frame exceeds the 1 MB protocol limit");
  }
  return V7AdapterMessageSchema.parse(JSON.parse(frame));
}

export function serializeV7AdapterFrame(input: V7AdapterMessage): string {
  const frame = JSON.stringify(V7AdapterMessageSchema.parse(input));
  if (new TextEncoder().encode(frame).byteLength > V7_ADAPTER_MAX_FRAME_BYTES) {
    throw new RangeError("Adapter frame exceeds the 1 MB protocol limit");
  }
  return frame;
}
