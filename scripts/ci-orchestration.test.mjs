import { describe, expect, it } from "vitest";
import {
  readFileSync,
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  chmodSync,
  rmSync,
  copyFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const source = (path) =>
  readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

describe("CI acceptance orchestration", () => {
  it("gives both explicit Cloud fixture files exactly one test owner", () => {
    const scripts = JSON.parse(source("package.json")).scripts;
    for (const file of [
      "v8-schema-clean-room-acceptance.test.ts",
      "work-v1-v8-regression.acceptance.test.ts",
    ]) {
      expect(scripts.test).toContain(`--exclude apps/cloud/test/${file}`);
      expect(scripts["check:fixture-e2e"]).toContain(`apps/cloud/test/${file}`);
    }
    expect(
      scripts["check:typescript"].match(/check:fixture-e2e/g),
    ).toHaveLength(1);
    expect(scripts.check).toContain("check:apps");
    expect(source("scripts/check-dart-packages.sh")).not.toMatch(
      /apps\/(app|workspace|profile_lab)/,
    );
  });

  it("aggregation rejects failed and skipped domains", () => {
    const workflow = source(".github/workflows/test-full.yml");
    const gateSection = workflow.slice(workflow.indexOf("  acceptance-gate:"));
    const dependencies = gateSection
      .match(/needs:\s*\[([\s\S]*?)\]/)[1]
      .split(",")
      .map((name) => name.trim())
      .filter(Boolean);
    expect(dependencies.sort()).toEqual(
      [
        "repo-static",
        "typescript",
        "dart-core",
        "app-flutter",
        "workspace-check",
        "workspace-macos-build",
        "profile-lab-macos",
        "site-astro",
      ].sort(),
    );
    const gate = workflow.match(
      /python3 - <<'PY_GATE'\n([\s\S]*?)\n\s+PY_GATE/,
    )[1];
    const script = gate
      .split("\n")
      .map((line) => line.slice(10))
      .join("\n");
    for (const result of ["success", "failure", "skipped", "cancelled"]) {
      const run = spawnSync("python3", ["-c", script], {
        env: {
          ...process.env,
          NEEDS_JSON: JSON.stringify({ domain: { result } }),
        },
      });
      expect(run.status, run.stderr.toString()).toBe(
        result === "success" ? 0 : 1,
      );
    }
    expect(workflow).toContain("cancel-in-progress: true");
    expect(workflow).not.toContain("windows-latest");
    expect(workflow).not.toContain("pnpm check\n");
  });

  it.each(["workspace", "profile-lab"])(
    "%s prepared build reuses preparation; default release cleans",
    (name) => {
      const root = mkdtempSync(join(tmpdir(), "conclave-ci-"));
      const appName = name.replaceAll("-", "_");
      const app = join(root, "apps", appName);
      const bin = join(root, "bin");
      const log = join(root, "commands");
      mkdirSync(join(root, "scripts"), { recursive: true });
      mkdirSync(join(app, ".dart_tool"), { recursive: true });
      mkdirSync(join(app, "assets", "engines"), { recursive: true });
      mkdirSync(bin);
      writeFileSync(join(app, "pubspec.yaml"), "version: 1.0.0\n");
      writeFileSync(join(app, ".dart_tool", "package_config.json"), "{}\n");
      const engine = join(
        app,
        "assets",
        "engines",
        "conclave_cli_worker_engine",
      );
      writeFileSync(engine, "#!/bin/sh\nexit 0\n");
      chmodSync(engine, 0o755);
      for (const command of ["uname", "node", "flutter", "ditto"]) {
        const script =
          command === "uname"
            ? "echo Darwin"
            : command === "node"
              ? "echo '{}'"
              : command === "flutter"
                ? `echo "flutter $*" >> "$CI_TEST_LOG"\nif [ "$1" = build ]; then mkdir -p 'build/macos/Build/Products/Release/Conclave ${name === "workspace" ? "Workspace" : "Profile Lab"}.app'; fi`
                : "exit 0";
        writeFileSync(join(bin, command), `#!/bin/sh\n${script}\n`);
        chmodSync(join(bin, command), 0o755);
      }
      writeFileSync(
        join(root, "scripts", "build-cli-worker-engine.sh"),
        'echo engine >> "$CI_TEST_LOG"\n',
      );
      const script = join(root, "scripts", `build-${name}-macos.sh`);
      copyFileSync(
        new URL(`../scripts/build-${name}-macos.sh`, import.meta.url),
        script,
      );
      const run = (args) =>
        spawnSync("bash", [script, ...args], {
          env: {
            ...process.env,
            PATH: `${bin}:${process.env.PATH}`,
            CI_TEST_LOG: log,
          },
        });
      try {
        const prepared = run(["--prepared"]);
        expect(prepared.status, prepared.stderr.toString()).toBe(0);
        expect(readFileSync(log, "utf8")).toBe(
          "flutter build macos --release --dart-define=" +
            (name === "workspace"
              ? "CONCLAVE_WORKSPACE_VERSION"
              : "CONCLAVE_PROFILE_LAB_VERSION") +
            "=1.0.0 --dart-define=CONCLAVE_RELEASE_TRUST_KEYS_JSON={}\n",
        );
        writeFileSync(log, "");
        expect(run([]).status).toBe(0);
        expect(readFileSync(log, "utf8")).toContain(
          "flutter clean\nflutter pub get\nengine\n",
        );
        rmSync(engine);
        expect(run(["--prepared"]).status).toBe(1);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
  );

  it("public site production deployment is decoupled with path filtering and self-contained validation", () => {
    const workflow = source(".github/workflows/deploy-site-production.yml");
    expect(workflow).toContain("branches: [main]");
    expect(workflow).toContain('paths:\n      - "apps/site/**"');
    expect(workflow).toContain("workflow_dispatch:");
    expect(workflow).toContain("cancel-in-progress: true");
    expect(workflow).not.toContain('workflows: ["CI"]');
    expect(workflow).not.toContain("workflow_run:");

    // Ensures site builds and all validations are present
    expect(workflow).toContain("./node_modules/.bin/astro check");
    expect(workflow).toContain("./node_modules/.bin/astro build");
    expect(workflow).toContain("node scripts/check-performance.mjs");
    expect(workflow).toContain("node scripts/check-accessibility.mjs");
    expect(workflow).toContain("node scripts/check-responsive.mjs");
    expect(workflow).toContain("node scripts/check-analytics-privacy.mjs");
    expect(workflow).toContain("node scripts/check-security.mjs");
    expect(workflow).toContain("node scripts/check-content.mjs");
    expect(workflow).toContain("node scripts/check-release.mjs");
    expect(workflow).toContain("./node_modules/.bin/vitest run test");
    expect(workflow).toContain("Verify static routes");
    expect(workflow).toContain(
      "../../node_modules/.bin/wrangler deploy --config wrangler.production.jsonc",
    );
  });
});
