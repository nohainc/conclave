/* eslint-disable @typescript-eslint/no-explicit-any */
import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { afterEach, describe, expect, it } from "vitest";
import {
  RealtimeGateway,
  type RealtimeScope,
} from "../src/realtime-gateway.js";
import { BoundedRealtimeQueue } from "../src/realtime-queue.js";

const databases: DatabaseSync[] = [];
afterEach(() => databases.splice(0).forEach((db) => db.close()));

function harness() {
  const database = new DatabaseSync(":memory:");
  databases.push(database);
  database.exec(`
    CREATE TABLE realtime_events (
      event_id TEXT, event_type TEXT, payload_json TEXT, occurred_at TEXT,
      sequence INTEGER, stream_kind TEXT, stream_id TEXT, workspace_id TEXT,
      space_id TEXT, thread_id TEXT, run_id TEXT
    );
    CREATE TABLE execution_workspaces (id TEXT, owner_user_id TEXT);
    INSERT INTO execution_workspaces VALUES ('W', 'U');
    CREATE TABLE space_memberships (space_id TEXT, user_id TEXT);
    INSERT INTO space_memberships VALUES ('S', 'U');
  `);
  const db = {
    prepare(sql: string) {
      return {
        bind: (...values: SQLInputValue[]) => ({
          all: async () => ({ results: database.prepare(sql).all(...values) }),
        }),
      };
    },
  };
  const frames: Array<Record<string, any>> = [];
  const cursors = new Map<string, number>();
  const connected = {
    socket: {
      readyState: 1,
      bufferedAmount: 0,
      send: (text: string) => frames.push(JSON.parse(text)),
    },
    identity: { userId: "U" },
    subscriptions: new Map(),
    lastDurableSequences: cursors,
    queue: new BoundedRealtimeQueue(),
    flushScheduled: false,
  };
  const gateway = new RealtimeGateway(
    {} as never,
    { SYNTILA_DB: db } as never,
  );
  const replay = (scope: RealtimeScope) =>
    Reflect.get(gateway, "replayScope").call(
      gateway,
      connected,
      scope,
    ) as Promise<void>;
  function insert(
    kind: string,
    id: string,
    count: number,
    type = "discussion.updated",
  ) {
    const statement = database.prepare(
      `INSERT INTO realtime_events VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'S', 'T', 'R')`,
    );
    for (let sequence = 1; sequence <= count; sequence++) {
      statement.run(
        `${kind}-${id}-${sequence}`,
        kind === "execution_workspace" ? "run.completed" : type,
        '{"entityId":"message","threadId":"T"}',
        "2026-10-15T00:00:00.000Z",
        sequence,
        kind,
        id,
        kind === "execution_workspace" ? id : null,
      );
    }
  }
  return { frames, cursors, replay, insert };
}

const cases: Array<[string, RealtimeScope, string, string]> = [
  ["user", { kind: "user" }, "user", "U"],
  ["space", { kind: "space", spaceId: "S" }, "space", "S"],
  ["thread", { kind: "thread", threadId: "T" }, "space", "S"],
  [
    "execution_workspace",
    { kind: "execution_workspace", executionWorkspaceId: "W" },
    "execution_workspace",
    "W",
  ],
];

describe("cursor-aware SQL replay", () => {
  for (const [name, scope, kind, id] of cases) {
    it(`${name}: replays event 301 after cursor 300 instead of the oldest 256`, async () => {
      const f = harness();
      f.insert(kind, id, 301);
      f.cursors.set(JSON.stringify([kind, id]), 300);
      await f.replay(scope);
      expect(f.frames.map((frame) => frame.event?.sequence)).toEqual([301]);
    });
    it(`${name}: a full replay page reports possible truncation`, async () => {
      const f = harness();
      f.insert(kind, id, 257);
      await f.replay(scope);
      expect(f.frames.filter((frame) => frame.type === "event")).toHaveLength(
        256,
      );
      expect(f.frames.at(-1)).toEqual({
        type: "reconnect.required",
        reason: "replay_limit",
        scope,
      });
      expect(f.cursors.get(JSON.stringify([kind, id]))).toBe(256);
    });
    it(`${name}: an unknown stream starts from its first event`, async () => {
      const f = harness();
      f.insert(kind, id, 2, "discussion.deleted");
      f.cursors.set('["space","unrelated"]', 900);
      await f.replay(scope);
      expect(f.frames.map((frame) => frame.event?.sequence)).toEqual([1, 2]);
    });
  }
  it("user scope filters every audience branch and excludes unauthorized streams", async () => {
    const f = harness();
    f.insert("user", "U", 301);
    f.insert("space", "S", 301);
    f.insert("execution_workspace", "W", 301);
    f.insert("space", "private", 1);
    for (const [kind, id] of [
      ["user", "U"],
      ["space", "S"],
      ["execution_workspace", "W"],
    ]) {
      f.cursors.set(JSON.stringify([kind, id]), 300);
    }
    await f.replay({ kind: "user" });
    expect(f.frames).toHaveLength(3);
    expect(f.frames.every((frame) => frame.event.sequence === 301)).toBe(true);
  });
  it("exactly 256 rows conservatively signals a gap", async () => {
    const f = harness();
    f.insert("space", "S", 256);
    await f.replay({ kind: "space", spaceId: "S" });
    expect(f.frames.at(-1)?.reason).toBe("replay_limit");
  });
});
