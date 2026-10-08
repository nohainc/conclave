import { z } from "zod";

/** Engine-owned limits. Profiles cannot raise these values. */
export const TOOL_PROFILE_LIMITS = Object.freeze({
  payloadBytes: 256 * 1024,
  stringLength: 4096,
  shortStringLength: 256,
  arrayItems: 64,
  arguments: 128,
  eventRules: 128,
  progressRules: 64,
  errorMappings: 64,
  selectorsPerRule: 16,
  selectorDepth: 16,
  selectorLength: 256,
  jsonValueDepth: 16,
  compatibilityOverrides: 16,
  environmentNames: 64,
  configChecks: 8,
  configFileBytes: 64 * 1024,
});

const boundedString = z.string().min(1).max(TOOL_PROFILE_LIMITS.stringLength);
const shortString = z
  .string()
  .min(1)
  .max(TOOL_PROFILE_LIMITS.shortStringLength);
const identifier = z
  .string()
  .regex(/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/)
  .max(96);
const semver = z
  .string()
  .regex(
    /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/,
  )
  .max(96);
const issueCode = z.enum([
  "provider_authentication_required",
  "provider_tool_unavailable",
  "unsupported_provider_tool_version",
  "model_not_supported",
  "permission_denied",
  "quota_exhausted",
  "provider_unavailable",
  "deadline_exceeded",
  "cancelled",
  "session_resume_failed",
  "provider_failure",
]);
const stderrPatternId = z.enum([
  "session_unavailable",
  "cancelled",
  "deadline_exceeded",
  "provider_tool_unavailable",
  "provider_authentication_required",
  "permission_denied",
  "quota_exhausted",
  "provider_unavailable",
  "provider_failure",
]);
const selector = z
  .string()
  .max(TOOL_PROFILE_LIMITS.selectorLength)
  .regex(/^\$(?:\.[A-Za-z_][A-Za-z0-9_]*)+$/)
  .superRefine((value, ctx) => {
    const depth = value.split(".").length - 1;
    if (depth > TOOL_PROFILE_LIMITS.selectorDepth) {
      ctx.addIssue({
        code: "custom",
        message: `Selector depth exceeds ${TOOL_PROFILE_LIMITS.selectorDepth}`,
      });
    }
    if (
      value
        .split(".")
        .some((part) =>
          ["__proto__", "prototype", "constructor"].includes(part),
        )
    ) {
      ctx.addIssue({
        code: "custom",
        message: "Selectors cannot address prototype properties",
      });
    }
  });
const envName = z.string().regex(/^[A-Za-z_][A-Za-z0-9_]{0,127}$/);
const approvedEnvName = envName.refine(
  (name) => !/^(?:CONCLAVE_|CLOUD_|WORKER_)/i.test(name),
  "Reserved environment name",
);
const placeholderNames = [
  "prompt",
  "model",
  "reasoningEffort",
  "sessionId",
  "timeoutMs",
  "timeoutSeconds",
  "workingDirectory",
  "home",
  "workerStateDirectory",
] as const;
const templatedString = boundedString.superRefine((value, ctx) => {
  const placeholders = [...value.matchAll(/\{\{([^{}]+)\}\}/g)];
  const scrubbed = value.replace(/\{\{[^{}]+\}\}/g, "");
  if (/\{\{|\}\}/.test(scrubbed))
    ctx.addIssue({ code: "custom", message: "Malformed placeholder" });
  for (const [, name] of placeholders) {
    if (!name || !(placeholderNames as readonly string[]).includes(name)) {
      ctx.addIssue({ code: "custom", message: `Unknown placeholder: ${name}` });
    }
  }
});
const argumentValues = z
  .array(templatedString)
  .min(1)
  .max(TOOL_PROFILE_LIMITS.arguments);
function jsonTemplateValueAt(depth: number): z.ZodType {
  const scalar = [
    z.null(),
    z.boolean(),
    z.number().finite(),
    templatedString,
  ] as const;
  if (depth >= TOOL_PROFILE_LIMITS.jsonValueDepth) return z.union(scalar);
  const child = jsonTemplateValueAt(depth + 1);
  const object = z
    .record(z.string().min(1).max(128), child)
    .superRefine((value, ctx) => {
      if (Object.keys(value).length > TOOL_PROFILE_LIMITS.arrayItems) {
        ctx.addIssue({
          code: "custom",
          message: "Too many JSON template properties",
        });
      }
    });
  return z.union([
    ...scalar,
    z.array(child).max(TOOL_PROFILE_LIMITS.arrayItems),
    object,
  ]);
}
const jsonTemplateValue = jsonTemplateValueAt(0);
const jsonTemplateObject = z
  .record(z.string().min(1).max(128), jsonTemplateValue)
  .superRefine((value, ctx) => {
    if (Object.keys(value).length > TOOL_PROFILE_LIMITS.arrayItems)
      ctx.addIssue({
        code: "custom",
        message: "Too many JSON template properties",
      });
  });
const discoveryLocation = templatedString.refine((path) => {
  if (
    ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].includes(path)
  )
    return true;
  if (!path.startsWith("{{home}}/")) return false;
  const relative = path.slice("{{home}}/".length);
  return [
    ".local/bin",
    ".npm-global/bin",
    ".npm/bin",
    ".volta/bin",
    ".bun/bin",
    ".gemini/antigravity-cli/bin",
    "AppData/Local/agy/bin",
    "AppData/Local/Programs/nodejs",
  ].includes(relative);
}, "Must be a home-relative location or an Engine-approved standard location");

const versionRange = z.object({ min: semver, maxExclusive: semver }).strict();
const providerCondition = z.discriminatedUnion("kind", [
  z
    .object({
      kind: z.literal("equals"),
      selector,
      value: z.union([shortString, z.number(), z.boolean(), z.null()]),
    })
    .strict(),
  z
    .object({
      kind: z.literal("not_equals"),
      selector,
      value: z.union([shortString, z.number(), z.boolean(), z.null()]),
    })
    .strict(),
  z
    .object({
      kind: z.literal("one_of"),
      selector,
      values: z
        .array(z.union([shortString, z.number(), z.boolean(), z.null()]))
        .min(1)
        .max(16),
    })
    .strict(),
  z
    .object({
      kind: z.literal("type_is"),
      selector,
      value: z.enum(["string", "number", "boolean", "object", "array", "null"]),
    })
    .strict(),
  z
    .object({ kind: z.literal("exists"), selector, exists: z.boolean() })
    .strict(),
]);
const conditions = z
  .array(providerCondition)
  .max(TOOL_PROFILE_LIMITS.selectorsPerRule);

const argument = z.union([
  templatedString,
  z
    .object({
      ifPresent: z.enum(["model", "sessionId", "reasoningEffort"]),
      values: argumentValues,
    })
    .strict(),
  z
    .object({
      ifAbsent: z.literal("sessionId"),
      ifSessionPolicy: z.literal("stateless"),
      values: argumentValues,
    })
    .strict(),
  z
    .object({
      sandboxPolicyMapping: z.literal(true),
    })
    .strict(),
  z.object({ modelArguments: z.literal(true) }).strict(),
  z.object({ sessionResumeArguments: z.literal(true) }).strict(),
  z.object({ providerTimeoutArguments: z.literal(true) }).strict(),
]);

const action = z.discriminatedUnion("type", [
  z.object({ type: z.literal("set_session"), selector }).strict(),
  z.object({ type: z.literal("set_final_text"), selector }).strict(),
  z.object({ type: z.literal("set_terminal_status"), selector }).strict(),
  z.object({ type: z.literal("set_provider_error"), selector }).strict(),
  z
    .object({
      type: z.literal("emit_progress"),
      percentage: z.number().int().min(0).max(100),
      messageKey: z.enum([
        "provider_working",
        "provider_tool_started",
        "provider_response_received",
        "provider_finalizing",
      ]),
    })
    .strict(),
  z.object({ type: z.literal("mark_success") }).strict(),
  z.object({ type: z.literal("mark_failure") }).strict(),
]);
const eventRule = z
  .object({ when: conditions.min(1), actions: z.array(action).min(1).max(16) })
  .strict();
const progressRule = z
  .object({
    when: conditions.min(1),
    percentage: z.number().int().min(0).max(100),
    messageKey: z.enum([
      "provider_working",
      "provider_tool_started",
      "provider_response_received",
      "provider_finalizing",
    ]),
  })
  .strict();

const passiveCommand = z
  .object({
    id: identifier,
    arguments: z.array(templatedString).max(TOOL_PROFILE_LIMITS.arguments),
    timeoutMs: z.number().int().min(100).max(30_000),
    successExitCodes: z.array(z.number().int().min(0).max(255)).min(1).max(16),
    failureIssueCode: issueCode,
  })
  .strict();
const configCheck = z
  .object({
    id: identifier,
    root: z.literal("home"),
    relativePath: z
      .string()
      .min(1)
      .max(512)
      .regex(/^[A-Za-z0-9./-]+$/)
      .refine(
        (path) =>
          !path.startsWith("/") &&
          path
            .split("/")
            .every((part) => part.length > 0 && part !== "." && part !== ".."),
        "Must be a safe home-relative path",
      ),
    format: z.literal("json"),
    maxBytes: z.number().int().min(1).max(TOOL_PROFILE_LIMITS.configFileBytes),
    onMissing: z.enum(["warning", "failed"]),
    onInvalid: z.enum(["warning", "failed"]),
    onNoMatch: z
      .object({
        result: z.enum(["passed", "warning", "failed"]),
        issueCode: issueCode.optional(),
      })
      .strict(),
    rules: z
      .array(
        z
          .object({
            when: conditions.min(1),
            result: z.enum(["passed", "warning", "failed"]),
            issueCode: issueCode.optional(),
            requiredEnvironmentAny: z
              .array(approvedEnvName)
              .max(TOOL_PROFILE_LIMITS.environmentNames)
              .optional(),
            whenEnvironmentMissing: z
              .object({
                result: z.enum(["passed", "warning", "failed"]),
                issueCode: issueCode.optional(),
              })
              .strict()
              .optional(),
          })
          .strict(),
      )
      .max(32),
  })
  .strict();

const errorMapping = z
  .object({
    evidence: z.discriminatedUnion("kind", [
      z
        .object({
          kind: z.literal("exit_code"),
          value: z.number().int().min(0).max(255),
        })
        .strict(),
      z
        .object({ kind: z.literal("terminal_status"), value: shortString })
        .strict(),
      z
        .object({
          kind: z.literal("stderr_pattern"),
          patternId: stderrPatternId,
        })
        .strict(),
      z.object({ kind: z.literal("missing_terminal") }).strict(),
      z
        .object({ kind: z.literal("structured_provider_error"), selector })
        .strict(),
    ]),
    issueCode,
  })
  .strict();

const modelId = shortString.max(160);
const effortValue = shortString.max(64);

const modelCatalogEntry = z
  .object({
    id: modelId,
    name: shortString,
    badge: shortString.optional(),
    description: shortString.optional(),
    defaultReasoningEffort: effortValue.optional(),
    supportedReasoningEfforts: z.array(effortValue).max(16).optional(),
    minProviderVersion: semver.optional(),
    maxProviderVersion: semver.optional(),
  })
  .strict();

const profileSchema = z
  .object({
    schemaVersion: z.literal(1),
    profileDefinitionId: identifier,
    releaseVersion: z.number().int().min(1).max(2_147_483_647),
    logicalWorkerTypeId: identifier,
    engineFamily: z.literal("cli"),
    engineCompatibility: versionRange,
    providerTool: z
      .object({
        name: shortString,
        executableCandidates: z
          .array(z.string().regex(/^[A-Za-z0-9._+-]{1,128}$/))
          .min(1)
          .max(16),
        discovery: z
          .object({
            standardLocations: z
              .array(discoveryLocation)
              .max(TOOL_PROFILE_LIMITS.arrayItems),
            allowPathSearch: z.boolean(),
          })
          .strict(),
        versionProbe: z
          .object({
            arguments: z
              .array(templatedString)
              .max(TOOL_PROFILE_LIMITS.arguments),
            timeoutMs: z.number().int().min(100).max(30_000),
            source: z.enum(["stdout", "stderr"]),
            extract: z
              .object({
                kind: z.literal("regex_capture"),
                patternId: z.literal("semver"),
              })
              .strict(),
          })
          .strict(),
        // Empty means provider compatibility has not been established yet.
        // Cloud publication and signed-release admission require a non-empty
        // range after local qualification.
        supportedVersions: z.array(versionRange).max(16),
      })
      .strict(),
    environment: z
      .object({
        passthrough: z
          .array(approvedEnvName)
          .max(TOOL_PROFILE_LIMITS.environmentNames),
        set: z
          .record(approvedEnvName, templatedString)
          .superRefine((record, ctx) => {
            if (
              Object.keys(record).length > TOOL_PROFILE_LIMITS.environmentNames
            )
              ctx.addIssue({
                code: "custom",
                message: "Too many environment variables",
              });
          }),
      })
      .strict(),
    probe: z
      .object({
        passive: z
          .object({
            checks: z.array(passiveCommand).max(16),
            configChecks: z
              .array(configCheck)
              .max(TOOL_PROFILE_LIMITS.configChecks),
          })
          .strict(),
        live: z
          .object({
            timeoutMs: z.number().int().min(100).max(60_000),
            expectedFinalText: z
              .object({ kind: z.literal("exact"), value: z.literal("OK") })
              .strict(),
          })
          .strict()
          .optional(),
      })
      .strict(),
    execution: z
      .object({
        arguments: z.array(argument).max(TOOL_PROFILE_LIMITS.arguments),
        stdin: z.discriminatedUnion("mode", [
          z
            .object({ mode: z.literal("raw_text"), value: templatedString })
            .strict(),
          z
            .object({
              mode: z.literal("json_object"),
              value: jsonTemplateObject,
              appendNewline: z.boolean(),
            })
            .strict(),
        ]),
        output: z
          .object({ mode: z.enum(["plain_text", "single_json", "jsonl"]) })
          .strict(),
        events: z.array(eventRule).max(TOOL_PROFILE_LIMITS.eventRules),
      })
      .strict(),
    session: z
      .object({
        supported: z.boolean(),
        formatId: shortString.regex(/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/),
        compatibleFormatIds: z
          .array(shortString.regex(/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/))
          .min(1)
          .max(16),
        extract: selector.optional(),
        resumeArguments: z
          .array(templatedString)
          .max(TOOL_PROFILE_LIMITS.arguments),
        requireObservedIdMatch: z.boolean(),
      })
      .strict()
      .superRefine((session, context) => {
        if (!session.compatibleFormatIds.includes(session.formatId)) {
          context.addIssue({
            code: "custom",
            path: ["compatibleFormatIds"],
            message: "Compatibility must include the current session format",
          });
        }
        if (
          new Set(session.compatibleFormatIds).size !==
          session.compatibleFormatIds.length
        ) {
          context.addIssue({
            code: "custom",
            path: ["compatibleFormatIds"],
            message: "Compatible session formats must be unique",
          });
        }
      }),
    model: z
      .object({
        supported: z.boolean(),
        arguments: z.array(templatedString).max(TOOL_PROFILE_LIMITS.arguments),
        unknownModelPolicy: z.enum(["pass_through", "profile_allowlist"]),
        allowlist: z.array(modelId).max(128).optional(),
        catalog: z.array(modelCatalogEntry).max(128).optional(),
        executionOptions: z
          .object({
            schemaVersion: z.literal(1),
            discovery: z.literal("profile_catalog"),
            modelSwitchSupported: z.boolean(),
            effortSupported: z.boolean(),
            defaultModelId: modelId.nullable().optional(),
            effortMapping: z
              .record(effortValue, shortString)
              .refine(
                (mapping) => Object.keys(mapping).length <= 128,
                "Too many effort mappings",
              )
              .optional(),
          })
          .strict()
          .optional(),
        defaultReasoningEffort: effortValue.optional(),
        supportedReasoningEfforts: z.array(effortValue).max(16).optional(),
      })
      .strict(),
    timeout: z
      .object({
        providerArguments: z
          .array(templatedString)
          .max(TOOL_PROFILE_LIMITS.arguments),
        providerReserveMs: z.number().int().min(0).max(30_000),
      })
      .strict(),
    sandbox: z
      .object({
        mappings: z
          .object({
            restricted: z
              .array(templatedString)
              .max(TOOL_PROFILE_LIMITS.arguments),
            provider_default: z
              .array(templatedString)
              .max(TOOL_PROFILE_LIMITS.arguments),
            full_access: z
              .array(templatedString)
              .max(TOOL_PROFILE_LIMITS.arguments),
          })
          .strict(),
      })
      .strict(),
    progress: z.array(progressRule).max(TOOL_PROFILE_LIMITS.progressRules),
    errors: z
      .object({
        mappings: z.array(errorMapping).max(TOOL_PROFILE_LIMITS.errorMappings),
      })
      .strict(),
    capabilities: z
      .array(
        z.enum([
          "text",
          "local_file",
          "thread_read",
          "thread_write",
          "durable_session",
          "image",
          "audio",
          "video",
        ]),
      )
      .max(32),
    compatibilityOverrides: z
      .array(
        z
          .object({
            providerVersion: versionRange,
            executionArguments: z
              .array(argument)
              .max(TOOL_PROFILE_LIMITS.arguments)
              .optional(),
            versionProbeArguments: z
              .array(templatedString)
              .max(TOOL_PROFILE_LIMITS.arguments)
              .optional(),
            progress: z
              .array(progressRule)
              .max(TOOL_PROFILE_LIMITS.progressRules)
              .optional(),
            errorMappings: z
              .array(errorMapping)
              .max(TOOL_PROFILE_LIMITS.errorMappings)
              .optional(),
          })
          .strict(),
      )
      .max(TOOL_PROFILE_LIMITS.compatibilityOverrides),
  })
  .strict();

export type ToolProfileV1 = z.infer<typeof profileSchema>;

function compareVersion(left: string, right: string): number {
  const parse = (version: string) => {
    const withoutBuild = version.split("+", 1)[0]!;
    const separator = withoutBuild.indexOf("-");
    const core =
      separator < 0 ? withoutBuild : withoutBuild.slice(0, separator);
    const prerelease =
      separator < 0 ? undefined : withoutBuild.slice(separator + 1);
    return {
      core: core.split(".").map(BigInt),
      prerelease: prerelease?.split("."),
    };
  };
  const a = parse(left);
  const b = parse(right);
  for (let i = 0; i < 3; i += 1) {
    if (a.core[i] !== b.core[i]) return a.core[i]! < b.core[i]! ? -1 : 1;
  }
  if (a.prerelease === undefined || b.prerelease === undefined) {
    if (a.prerelease === b.prerelease) return 0;
    return a.prerelease === undefined ? 1 : -1;
  }
  const length = Math.max(a.prerelease.length, b.prerelease.length);
  for (let i = 0; i < length; i += 1) {
    const ai = a.prerelease[i];
    const bi = b.prerelease[i];
    if (ai === undefined || bi === undefined)
      return ai === bi ? 0 : ai === undefined ? -1 : 1;
    if (ai === bi) continue;
    const an = /^(0|[1-9]\d*)$/.test(ai);
    const bn = /^(0|[1-9]\d*)$/.test(bi);
    if (an && bn) return BigInt(ai) < BigInt(bi) ? -1 : 1;
    if (an !== bn) return an ? -1 : 1;
    return ai < bi ? -1 : 1;
  }
  return 0;
}
function validateRange(
  min: string,
  max: string,
  path: (string | number)[],
  ctx: z.RefinementCtx,
): void {
  if (compareVersion(min, max) >= 0)
    ctx.addIssue({
      code: "custom",
      path,
      message: "Version range must be non-empty and increasing",
    });
}
function pathsDisjoint(
  left: { min: string; maxExclusive: string },
  right: { min: string; maxExclusive: string },
): boolean {
  return (
    compareVersion(left.maxExclusive, right.min) <= 0 ||
    compareVersion(right.maxExclusive, left.min) <= 0
  );
}

export const toolProfileV1Schema = profileSchema.superRefine((profile, ctx) => {
  if (
    new TextEncoder().encode(JSON.stringify(profile)).byteLength >
    TOOL_PROFILE_LIMITS.payloadBytes
  )
    ctx.addIssue({
      code: "custom",
      message: `Tool Profile payload exceeds ${TOOL_PROFILE_LIMITS.payloadBytes} bytes`,
    });
  const model = profile.model;
  const optionIssue = (message: string) =>
    ctx.addIssue({ code: "custom", path: ["model"], message });
  const entries = model.catalog ?? [];
  if (new Set(entries.map((entry) => entry.id)).size !== entries.length)
    optionIssue("Model catalog IDs must be unique");
  for (const entry of [model, ...entries]) {
    const values =
      entry.supportedReasoningEfforts ?? model.supportedReasoningEfforts ?? [];
    const defaultEffort =
      entry.defaultReasoningEffort ?? model.defaultReasoningEffort;
    if (new Set(values).size !== values.length)
      optionIssue("Effort values must be unique");
    // An explicit empty list disables effort and does not inherit its default.
    if (defaultEffort && values.length > 0 && !values.includes(defaultEffort))
      optionIssue("Default effort must be supported");
  }
  const declared = model.executionOptions;
  if (declared) {
    if (
      declared.modelSwitchSupported &&
      (!model.supported || !profile.session.supported)
    )
      optionIssue(
        "Model switching requires model selection and durable sessions",
      );
    if (
      declared.defaultModelId &&
      (!model.supported ||
        !entries.some((entry) => entry.id === declared.defaultModelId))
    )
      optionIssue("Default model must be in the catalog");
    if (
      declared.defaultModelId &&
      model.unknownModelPolicy === "profile_allowlist" &&
      !model.allowlist?.includes(declared.defaultModelId)
    )
      optionIssue("Default model must be allowed");
    if (
      declared.effortSupported &&
      [
        profile.execution.arguments,
        ...profile.compatibilityOverrides.flatMap((override) =>
          override.executionArguments ? [override.executionArguments] : [],
        ),
      ].some(
        (arguments_) =>
          !JSON.stringify([arguments_, profile.execution.stdin]).includes(
            "{{reasoningEffort}}",
          ),
      )
    )
      optionIssue("Supported effort requires a provider invocation mapping");
    const supported = new Set([
      ...(model.supportedReasoningEfforts ?? []),
      ...entries.flatMap((entry) => entry.supportedReasoningEfforts ?? []),
    ]);
    if (
      !declared.effortSupported &&
      (supported.size > 0 ||
        Object.keys(declared.effortMapping ?? {}).length > 0)
    )
      optionIssue(
        "Disabled effort must not declare selectable values or mappings",
      );
    if (declared.effortSupported && supported.size === 0)
      optionIssue("Supported effort requires declared values");
    if (
      Object.keys(declared.effortMapping ?? {}).some(
        (value) => !supported.has(value),
      )
    )
      optionIssue("Effort mapping keys must be declared values");
  }
  const validateArgumentSlots = (
    args: ToolProfileV1["execution"]["arguments"],
    path: (string | number)[],
  ) => {
    const count = (key: string) =>
      args.filter(
        (part) => typeof part === "object" && part !== null && key in part,
      ).length;
    const expected = {
      sandboxPolicyMapping: 1,
      modelArguments:
        profile.model.supported && profile.model.arguments.length > 0 ? 1 : 0,
      sessionResumeArguments: profile.session.supported ? 1 : 0,
      providerTimeoutArguments: 1,
    };
    for (const [key, occurrences] of Object.entries(expected)) {
      if (count(key) !== occurrences)
        ctx.addIssue({
          code: "custom",
          path,
          message: `Execution arguments require ${occurrences} ${key} slot(s)`,
        });
    }
  };
  validateArgumentSlots(profile.execution.arguments, [
    "execution",
    "arguments",
  ]);
  profile.compatibilityOverrides.forEach((override, index) => {
    if (override.executionArguments)
      validateArgumentSlots(override.executionArguments, [
        "compatibilityOverrides",
        index,
        "executionArguments",
      ]);
  });
  validateRange(
    profile.engineCompatibility.min,
    profile.engineCompatibility.maxExclusive,
    ["engineCompatibility"],
    ctx,
  );
  profile.providerTool.supportedVersions.forEach((range, index) =>
    validateRange(
      range.min,
      range.maxExclusive,
      ["providerTool", "supportedVersions", index],
      ctx,
    ),
  );
  profile.compatibilityOverrides.forEach((override, index) =>
    validateRange(
      override.providerVersion.min,
      override.providerVersion.maxExclusive,
      ["compatibilityOverrides", index, "providerVersion"],
      ctx,
    ),
  );
  for (let i = 0; i < profile.compatibilityOverrides.length; i += 1) {
    for (let j = i + 1; j < profile.compatibilityOverrides.length; j += 1) {
      if (
        !pathsDisjoint(
          profile.compatibilityOverrides[i]!.providerVersion,
          profile.compatibilityOverrides[j]!.providerVersion,
        )
      ) {
        ctx.addIssue({
          code: "custom",
          path: ["compatibilityOverrides", j, "providerVersion"],
          message: "Compatibility override ranges must not overlap",
        });
      }
    }
  }
  if (profile.session.supported && !profile.session.extract)
    ctx.addIssue({
      code: "custom",
      path: ["session", "extract"],
      message: "Supported sessions require an extraction selector",
    });
  if (profile.session.supported && profile.session.resumeArguments.length === 0)
    ctx.addIssue({
      code: "custom",
      path: ["session", "resumeArguments"],
      message: "Supported sessions require resume arguments",
    });
  if (
    !profile.session.supported &&
    (profile.session.resumeArguments.length > 0 || profile.session.extract)
  )
    ctx.addIssue({
      code: "custom",
      path: ["session"],
      message:
        "Stateless profiles cannot define session extraction or resume arguments",
    });
  if (
    profile.model.unknownModelPolicy === "profile_allowlist" &&
    !profile.model.allowlist?.length
  )
    ctx.addIssue({
      code: "custom",
      path: ["model", "allowlist"],
      message: "profile_allowlist requires a non-empty allowlist",
    });
  if (
    profile.model.unknownModelPolicy === "pass_through" &&
    profile.model.allowlist
  )
    ctx.addIssue({
      code: "custom",
      path: ["model", "allowlist"],
      message: "pass_through profiles cannot define an allowlist",
    });
  if (profile.model.supported !== profile.model.arguments.length > 0)
    ctx.addIssue({
      code: "custom",
      path: ["model"],
      message: "Model support and model argument mapping must agree",
    });
  const passthrough = profile.environment.passthrough;
  if (new Set(passthrough).size !== passthrough.length)
    ctx.addIssue({
      code: "custom",
      path: ["environment", "passthrough"],
      message: "Environment names must be unique",
    });
  for (const name of passthrough) {
    if (Object.hasOwn(profile.environment.set, name))
      ctx.addIssue({
        code: "custom",
        path: ["environment", "set", name],
        message:
          "An environment variable cannot be both set and passed through",
      });
  }
  const capabilities = profile.capabilities;
  if (new Set(capabilities).size !== capabilities.length)
    ctx.addIssue({
      code: "custom",
      path: ["capabilities"],
      message: "Capabilities must be unique",
    });
  if (capabilities.includes("durable_session") && !profile.session.supported)
    ctx.addIssue({
      code: "custom",
      path: ["capabilities"],
      message: "durable_session requires session support",
    });
});

export const toolProfileV1JsonSchema = z.toJSONSchema(profileSchema, {
  target: "draft-2020-12",
});

/** Parse and validate the immutable behavior payload, including hard byte bounds. */
export function parseToolProfileV1(input: unknown): ToolProfileV1 {
  if (typeof input === "string") {
    if (
      new TextEncoder().encode(input).byteLength >
      TOOL_PROFILE_LIMITS.payloadBytes
    )
      throw new Error(
        `Tool Profile payload exceeds ${TOOL_PROFILE_LIMITS.payloadBytes} bytes`,
      );
    let decoded: unknown;
    try {
      decoded = JSON.parse(input);
    } catch {
      throw new Error("Tool Profile payload is not valid JSON");
    }
    return toolProfileV1Schema.parse(decoded);
  }
  const profile = toolProfileV1Schema.parse(input);
  if (
    new TextEncoder().encode(JSON.stringify(profile)).byteLength >
    TOOL_PROFILE_LIMITS.payloadBytes
  )
    throw new Error(
      `Tool Profile payload exceeds ${TOOL_PROFILE_LIMITS.payloadBytes} bytes`,
    );
  return profile;
}

export * from "./interpreter.js";
