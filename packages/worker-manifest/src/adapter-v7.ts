import { z } from "zod";
import { EXECUTION_ERROR_CODES } from "@conclave/protocol";

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

export const V7AdapterEnvironmentPolicySchema = z
  .object({
    environmentPassthrough: z
      .array(nonEmpty.regex(/^[A-Z_][A-Z0-9_]*$/))
      .max(64)
      .default([]),
    providerCliPassthrough: z
      .array(nonEmpty.regex(/^[A-Z_][A-Z0-9_]*$/))
      .max(64)
      .default([]),
    sensitivePassthrough: z
      .array(nonEmpty.regex(/^[A-Z_][A-Z0-9_]*$/))
      .max(64)
      .default([]),
  })
  .strict()
  .superRefine((policy, ctx) => {
    for (const [key, values] of Object.entries(policy)) {
      if (new Set(values).size !== values.length) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: [key],
          message: "Environment policy variable names must be unique",
        });
      }
    }
    const passthrough = new Set(policy.environmentPassthrough);
    for (const name of [
      ...policy.providerCliPassthrough,
      ...policy.sensitivePassthrough,
    ]) {
      if (!passthrough.has(name)) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ["environmentPassthrough"],
          message: `${name} must be included in environmentPassthrough`,
        });
      }
    }
  });

const probeIssueCode = z.enum([
  "setup_required",
  "cli_not_found",
  "worker_not_ready",
  "authentication_required",
  "unsupported_cli_version",
  "permission_configuration_required",
  "permission_denied",
  "execution_test_failed",
  "model_not_supported",
  "quota_exhausted",
  "provider_unavailable",
  "timeout",
  "cancelled",
  "internal_adapter_error",
  "execution_failed",
]);
const probeCheck = z
  .object({
    id: nonEmpty.max(64),
    status: z.enum(["passed", "failed", "skipped"]),
    issueCode: probeIssueCode.optional(),
    diagnostic: z.string().max(2048).optional(),
  })
  .strict()
  .superRefine((check, ctx) => {
    if (check.status === "failed" && !check.issueCode) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["issueCode"],
        message: "A failed probe check requires a stable issue code",
      });
    }
  });

export const V7AdapterManifestSchema = z
  .object({
    workerTypeId: nonEmpty.regex(slug),
    adapterVersion: nonEmpty.regex(semver),
    protocolVersion: z.enum(["2.1", "2.2", "2.3", "2.4", "2.5"]),
    publisher: nonEmpty,
    displayName: nonEmpty,
    supportedPlatforms: z.array(V7AdapterPlatformSchema).min(1).max(6),
    capabilities: z.array(nonEmpty).max(128),
    permissions: z.array(nonEmpty).max(64),
    authStrategies: z.array(V7AdapterAuthStrategySchema).min(1).max(4),
    modelSelectionMode: z.enum(["fixed", "allow_list", "automatic"]),
    prerequisites: z.array(V7AdapterPrerequisiteSchema).max(32).default([]),
    environmentPolicy: V7AdapterEnvironmentPolicySchema.optional(),
    // Legacy field accepted for already-published package manifests.
    environmentRequirements: z
      .array(nonEmpty.regex(/^[A-Z_][A-Z0-9_]*$/))
      .max(64)
      .optional(),
    executable: nonEmpty,
    launchArgs: z.array(z.string().max(2048)).max(64).default([]),
    secretRequirements: z
      .array(V7AdapterSecretRequirementSchema)
      .max(32)
      .default([]),
    healthCheck: z
      .object({
        mode: z.literal("protocol"),
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

export const V7_ADAPTER_PROTOCOL_VERSION = "2.5" as const;
export const V7_ADAPTER_MAX_FRAME_BYTES = 1_048_576;

const requestId = nonEmpty.max(128);
const assignmentId = nonEmpty.max(128);
const message = nonEmpty.max(16_384);
const adapterVersion = nonEmpty.max(128);
const safeEndpointUrl = z
  .string()
  .max(2048)
  .refine((value) => {
    try {
      const url = new URL(value);
      const local = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
      return (
        (url.protocol === "https:" || (local && url.protocol === "http:")) &&
        !url.username &&
        !url.password &&
        !url.search &&
        !url.hash
      );
    } catch {
      return false;
    }
  }, "Probe endpoint must not contain credentials or query data");
const probeConfig = z
  .object({
    mode: z.enum(["passive", "live"]).optional(),
    endpointUrl: safeEndpointUrl.optional(),
    organizationId: z.string().max(256).optional(),
    projectId: z.string().max(256).optional(),
  })
  .strict();
const adapterCapabilities = z.array(nonEmpty.max(128)).max(128);
const toolVersion = nonEmpty.max(128).nullable();
const issues = z
  .array(z.object({ code: nonEmpty.max(128), message }).strict())
  .max(128);

const requestBase = z.object({
  type: z.string(),
  protocolVersion: z.enum(["2.1", "2.2", "2.3", "2.4", "2.5"]),
});

export const V7AdapterMessageSchema = z
  .discriminatedUnion("type", [
    requestBase
      .extend({
        type: z.literal("initialize.request"),
        requestId,
        workerTypeId: nonEmpty.max(128),
        adapterVersion,
      })
      .strict(),
    requestBase
      .extend({
        type: z.literal("initialize.result"),
        requestId,
        adapterVersion,
        capabilities: adapterCapabilities,
      })
      .strict(),
    requestBase
      .extend({
        type: z.literal("probe.request"),
        requestId,
        mode: z.enum(["passive", "live"]).optional(),
        config: probeConfig.optional(),
      })
      .strict(),
    requestBase
      .extend({
        type: z.literal("probe.result"),
        requestId,
        ready: z.boolean(),
        toolVersion,
        mode: z.enum(["passive", "live"]).optional(),
        checks: z.array(probeCheck).min(1).max(16).optional(),
        checkKind: z.literal("readiness").optional(),
        issues: issues.optional(),
        models: z.array(nonEmpty.max(256)).max(500).optional(),
      })
      .strict(),
    requestBase
      .extend({
        type: z.literal("execute.request"),
        requestId,
        assignmentId,
        prompt: z.string().max(512_000),
        model: nonEmpty.max(256).optional(),
        timeoutMs: z.number().int().min(1).max(2_147_483_647).optional(),
        sessionPolicy: z.enum(["stateless", "durable_session"]).optional(),
        sessionKey: nonEmpty.max(256).optional(),
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
        code: z.enum(EXECUTION_ERROR_CODES),
        message,
        retryable: z.boolean(),
      })
      .strict(),
  ])
  .superRefine((message, ctx) => {
    if (
      message.type === "probe.request" &&
      ["2.3", "2.4", "2.5"].includes(message.protocolVersion)
    ) {
      if (!message.mode || message.config?.mode !== undefined) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ["mode"],
          message: "Protocol 2.3+ probes require passive or live mode",
        });
      }
    }
    if (
      message.type === "execute.request" &&
      ["2.4", "2.5"].includes(message.protocolVersion)
    ) {
      if (message.timeoutMs === undefined) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ["timeoutMs"],
          message: "Protocol 2.4+ execute requests require timeoutMs",
        });
      }
    }
    if (
      message.type === "execute.request" &&
      message.sessionKey !== undefined &&
      !["2.4", "2.5"].includes(message.protocolVersion)
    ) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["sessionKey"],
        message: "Logical session keys require protocol 2.4+",
      });
    }
    if (
      message.type === "execute.request" &&
      message.protocolVersion === "2.5"
    ) {
      if (
        !message.sessionPolicy ||
        (message.sessionPolicy === "stateless" &&
          message.sessionKey !== undefined) ||
        (message.sessionPolicy === "durable_session" &&
          message.sessionKey === undefined)
      ) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ["sessionPolicy"],
          message: "Protocol 2.5 session policy and key are inconsistent",
        });
      }
    }
    if (message.type !== "probe.result") return;
    if (["2.3", "2.4", "2.5"].includes(message.protocolVersion)) {
      if (
        !message.mode ||
        !message.checks ||
        message.checkKind !== undefined ||
        message.issues !== undefined ||
        new Set(message.checks.map((check) => check.id)).size !==
          message.checks.length ||
        (message.mode === "live" &&
          !message.checks.some((check) => check.id === "execution")) ||
        message.ready !==
          !message.checks.some((check) => check.status === "failed")
      ) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ["checks"],
          message: "Protocol 2.3+ probe checks are inconsistent",
        });
      }
    } else if (
      message.checkKind !== "readiness" ||
      !message.issues ||
      message.mode !== undefined ||
      message.checks !== undefined
    ) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["checkKind"],
        message: "Legacy probe result fields are invalid",
      });
    }
  });

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
