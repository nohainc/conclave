import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { afterEach, expect, it } from "vitest";

const roots = [];
afterEach(() => {
  for (const root of roots.splice(0))
    rmSync(root, { recursive: true, force: true });
});
it("packaging rejects missing, mismatched and altered build output", () => {
  const root = mkdtempSync(join(tmpdir(), "workspace-manifest-"));
  roots.push(root);
  mkdirSync(join(root, "assets/engines"), { recursive: true });
  for (const name of [
    "workspace",
    "conclave-workspace",
    "assets/engines/conclave_cli_worker_engine",
  ]) {
    writeFileSync(join(root, name), "fixture");
  }
  const run = (mode, version = "1.0.4") =>
    execFileSync(
      process.execPath,
      ["scripts/workspace-build-manifest.mjs", mode, root, version],
      { stdio: "pipe" },
    );
  expect(() => run("verify")).toThrow();
  run("record");
  expect(() => run("verify")).not.toThrow();
  expect(() => run("verify", "1.0.5")).toThrow();
  writeFileSync(join(root, "workspace"), "stale");
  expect(() => run("verify")).toThrow();
});
