import { it as test } from "vitest";
import assert from "node:assert/strict";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  existsSync,
  rmSync,
  symlinkSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { convertWorkspaceThreadMarkers } from "./convert-workspace-thread-markers.mjs";
function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "thread-cutover-"));
  t.onTestFinished(() => rmSync(root, { recursive: true, force: true }));
  const directory = join(root, "space-1", "thread-1");
  mkdirSync(directory, { recursive: true });
  const source = join(directory, ".conclave-workstream.json");
  const old = {
    schemaVersion: 1,
    projectId: "space-1",
    workstreamId: "thread-1",
    createdAt: "2026-10-07T23:08:59.750380Z",
  };
  writeFileSync(source, JSON.stringify(old));
  writeFileSync(join(directory, "user.txt"), "preserve");
  return { root, directory, source, old };
}
test("preview and conversion preserve IDs, timestamp, files and backup; rerun is empty", (t) => {
  const f = fixture(t);
  assert.equal(convertWorkspaceThreadMarkers(f.root).length, 1);
  assert.ok(existsSync(f.source));
  convertWorkspaceThreadMarkers(f.root, { apply: true });
  assert.deepEqual(
    JSON.parse(
      readFileSync(join(f.directory, ".conclave-thread.json"), "utf8"),
    ),
    {
      schemaVersion: 1,
      spaceId: "space-1",
      threadId: "thread-1",
      createdAt: f.old.createdAt,
    },
  );
  assert.deepEqual(
    JSON.parse(readFileSync(`${f.source}.pre-thread-cutover`, "utf8")),
    f.old,
  );
  assert.equal(readFileSync(join(f.directory, "user.txt"), "utf8"), "preserve");
  assert.deepEqual(convertWorkspaceThreadMarkers(f.root, { apply: true }), []);
});
test("rejects mismatched identities without adopting user data", (t) => {
  const f = fixture(t);
  writeFileSync(f.source, JSON.stringify({ ...f.old, projectId: "other" }));
  assert.throws(
    () => convertWorkspaceThreadMarkers(f.root, { apply: true }),
    /identity/,
  );
  assert.ok(!existsSync(join(f.directory, ".conclave-thread.json")));
});
test("rejects symlink marker and existing current marker", (t) => {
  const f = fixture(t);
  writeFileSync(join(f.directory, ".conclave-thread.json"), "{}");
  assert.throws(
    () => convertWorkspaceThreadMarkers(f.root, { apply: true }),
    /already exists/,
  );
  rmSync(join(f.directory, ".conclave-thread.json"));
  renameFixture();
  function renameFixture() {
    rmSync(f.source);
    symlinkSync(join(f.directory, "user.txt"), f.source);
  }
  assert.throws(
    () => convertWorkspaceThreadMarkers(f.root, { apply: true }),
    /Unsafe/,
  );
});
