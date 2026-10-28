import { existsSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const wranglerRequire = createRequire(require.resolve("wrangler/package.json"));
const parseJsonc = (source, filename) => {
  const config = wranglerRequire("jsonc-parser").parse(source, [], {
    allowTrailingComma: true,
  });
  if (!config || typeof config !== "object") {
    throw new Error(`Email configuration is not an object: ${filename}`);
  }
  return config;
};

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const LEGACY_SENDER = "auth@auth.earthuc.com";
const EXPECTED_PRODUCTION = Object.freeze({
  SYNTILA_EMAIL_FROM: "syntila@conclaveax.com",
  SYNTILA_EMAIL_FALLBACK_FROM: "vitalii@conclaveax.com",
  SYNTILA_EMAIL_FROM_NAME: "Syntila",
});

function readJsonc(rootDir, relativePath) {
  const filename = resolve(rootDir, relativePath);
  const source = readFileSync(filename, "utf8");
  return { filename, source, config: parseJsonc(source, filename) };
}

function addSenderErrors(errors, vars, label, expected = undefined) {
  for (const [name, value] of Object.entries(
    expected ?? {
      SYNTILA_EMAIL_FROM: vars?.SYNTILA_EMAIL_FROM,
      SYNTILA_EMAIL_FALLBACK_FROM: vars?.SYNTILA_EMAIL_FALLBACK_FROM,
      SYNTILA_EMAIL_FROM_NAME: vars?.SYNTILA_EMAIL_FROM_NAME,
    },
  )) {
    if (typeof value !== "string" || value.trim().length === 0) {
      errors.push(`${label}: ${name} is missing or empty`);
    }
  }
  const primary = vars?.SYNTILA_EMAIL_FROM?.trim().toLowerCase();
  const fallback = vars?.SYNTILA_EMAIL_FALLBACK_FROM?.trim().toLowerCase();
  if (primary && !EMAIL_PATTERN.test(primary)) {
    errors.push(`${label}: SYNTILA_EMAIL_FROM is not a valid email address`);
  }
  if (fallback && !EMAIL_PATTERN.test(fallback)) {
    errors.push(
      `${label}: SYNTILA_EMAIL_FALLBACK_FROM is not a valid email address`,
    );
  }
  if (primary === LEGACY_SENDER || fallback === LEGACY_SENDER) {
    errors.push(`${label}: retired sender is configured`);
  }
  if (primary && fallback && primary === fallback) {
    errors.push(`${label}: primary and fallback senders must differ`);
  }
  if (expected) {
    for (const [name, value] of Object.entries(expected)) {
      if (vars?.[name] !== value) {
        errors.push(`${label}: ${name} must be ${value}`);
      }
    }
  }
}

export function validateEmailDeploymentConfig(rootDir = process.cwd()) {
  const errors = [];
  const production = readJsonc(rootDir, "infra/cloudflare/app.wrangler.jsonc");
  const development = readJsonc(rootDir, "apps/cloud/wrangler.jsonc");

  if (production.config.vars?.SYNTILA_ENVIRONMENT !== "production") {
    errors.push("production: SYNTILA_ENVIRONMENT must be production");
  }
  addSenderErrors(
    errors,
    production.config.vars,
    "production",
    EXPECTED_PRODUCTION,
  );

  const binding = production.config.send_email?.some(
    (entry) => entry?.name === "SYNTILA_EMAIL",
  );
  if (!binding) {
    errors.push("production: SYNTILA_EMAIL send_email binding is missing");
  }
  if (production.source.includes(LEGACY_SENDER)) {
    errors.push("production: retired sender appears in Wrangler configuration");
  }

  if (development.config.vars?.SYNTILA_ENVIRONMENT !== "development") {
    errors.push("development: SYNTILA_ENVIRONMENT must be development");
  }
  const developmentBinding = development.config.send_email?.some(
    (entry) => entry?.name === "SYNTILA_EMAIL",
  );
  if (!developmentBinding) {
    errors.push("development: SYNTILA_EMAIL send_email binding is missing");
  }
  for (const name of Object.keys(EXPECTED_PRODUCTION)) {
    if (development.config.vars?.[name] !== undefined) {
      errors.push(
        `development: ${name} must remain unset; use apps/cloud/.dev.vars overrides`,
      );
    }
  }
  if (development.source.includes(LEGACY_SENDER)) {
    errors.push(
      "development: retired sender appears in Wrangler configuration",
    );
  }

  for (const relativePath of [
    "apps/cloud/src/auth/better-auth.ts",
    "apps/cloud/src/invitation-email.ts",
  ]) {
    const filename = resolve(rootDir, relativePath);
    if (
      existsSync(filename) &&
      readFileSync(filename, "utf8").includes(LEGACY_SENDER)
    ) {
      errors.push(
        `${relativePath}: retired sender appears in active email code`,
      );
    }
  }

  return errors;
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  const errors = validateEmailDeploymentConfig();
  if (errors.length > 0) {
    console.error(
      `Email configuration validation failed:\n- ${errors.join("\n- ")}`,
    );
    process.exitCode = 1;
  } else {
    console.log(
      "Email configuration validation passed; no messages were sent.",
    );
  }
}
