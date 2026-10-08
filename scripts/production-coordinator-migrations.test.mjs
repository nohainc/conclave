import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { describe, expect, it } from "vitest";

const require = createRequire(import.meta.url);
const wranglerRequire = createRequire(require.resolve("wrangler/package.json"));
const config = wranglerRequire("jsonc-parser").parse(
  readFileSync(
    new URL("../infra/cloudflare/app.wrangler.jsonc", import.meta.url),
    "utf8",
  ),
  [],
  { allowTrailingComma: true },
);

describe("production coordinator migration history", () => {
  it("preserves the applied creation and renames its namespace without deletion", () => {
    const creation = config.migrations.findIndex(
      (m) => m.tag === "v8-workstream-coordinator",
    );
    expect(creation).toBeGreaterThanOrEqual(0);
    expect(config.migrations[creation].new_sqlite_classes).toEqual([
      "WorkstreamExecutionCoordinator",
    ]);
    expect(config.migrations.slice(creation + 1)).toEqual([
      {
        tag: "v9-thread-coordinator-rename",
        renamed_classes: [
          {
            from: "WorkstreamExecutionCoordinator",
            to: "ThreadExecutionCoordinator",
          },
        ],
      },
    ]);
    expect(config.durable_objects.bindings).toContainEqual({
      name: "CONCLAVE_THREAD_COORDINATOR",
      class_name: "ThreadExecutionCoordinator",
    });
  });
});
