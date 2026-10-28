import { DatabaseSync } from "node:sqlite";
import { beforeEach, describe, expect, it, vi } from "vitest";
const authorize = vi.fn(async (..._args: unknown[]) => ({
  context: { userId: "owner" },
  spaceId: "space",
}));
vi.mock("../src/routes/thread-policy.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: (...args: unknown[]) => authorize(...args),
}));
vi.mock("../src/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: (...args: unknown[]) => authorize(...args),
}));
vi.mock("../src/collaboration-events.js", () => ({
  publishCollaborationEvent: async (
    _env: unknown,
    _type: string,
    _space: string,
    _entity: string,
    options: { mutations: { run(): Promise<unknown> }[] },
  ) => {
    for (const mutation of options.mutations) await mutation.run();
  },
}));
import {
  handleUploadWorkRequestFile,
  handleDownloadThreadFile,
  fileTextPreview,
  normalizeDiscussionAttachments,
} from "../src/routes/work-request-files.js";
import {
  handleCreateDiscussionMessage,
  handleListDiscussionMessages,
  handleEditDiscussionMessage,
} from "../src/routes/threads.js";

function fixture() {
  const sqlite = new DatabaseSync(":memory:");
  sqlite.exec(`CREATE TABLE users(id TEXT, display_name TEXT);
    CREATE TABLE discussion_messages(id TEXT, thread_id TEXT, author_user_id TEXT, body TEXT, references_json TEXT, attachments_json TEXT NOT NULL DEFAULT '[]', created_at TEXT, edited_at TEXT, event_type TEXT, kind TEXT DEFAULT 'message', work_request_id TEXT, worker_display_name TEXT, reply_to_json TEXT);
    CREATE TABLE work_requests(thread_id TEXT, input_json TEXT);
    CREATE TABLE user_files(id TEXT PRIMARY KEY, user_id TEXT, thread_id TEXT, space_id TEXT, name TEXT, media_type TEXT, size_bytes INTEGER, created_at TEXT);
    CREATE TABLE space_audit_log(id TEXT, space_id TEXT, actor_type TEXT, actor_id TEXT, action TEXT, target_type TEXT, target_id TEXT, details_json TEXT, created_at TEXT);`);
  const db = {
    prepare(sql: string) {
      let values: unknown[] = [];
      return {
        bind(...args: unknown[]) {
          values = args;
          return this;
        },
        async run() {
          return sqlite.prepare(sql).run(...(values as []));
        },
        async first() {
          return sqlite.prepare(sql).get(...(values as [])) ?? null;
        },
        async all() {
          return { results: sqlite.prepare(sql).all(...(values as [])) };
        },
      };
    },
  };
  const objects = new Map<
    string,
    {
      bytes: Uint8Array;
      customMetadata?: Record<string, string>;
      httpMetadata?: Record<string, string>;
    }
  >();
  const bucket = {
    async put(
      key: string,
      value: ArrayBuffer | string,
      options: {
        customMetadata?: Record<string, string>;
        httpMetadata?: Record<string, string>;
      },
    ) {
      objects.set(key, {
        bytes:
          typeof value === "string"
            ? new TextEncoder().encode(value)
            : new Uint8Array(value),
        ...options,
      });
    },
    async head(key: string) {
      const object = objects.get(key);
      return object ? { ...object, size: object.bytes.length } : null;
    },
    async get(key: string) {
      const object = objects.get(key);
      return object
        ? {
            ...object,
            size: object.bytes.length,
            body: object.bytes,
            json: async () =>
              JSON.parse(new TextDecoder().decode(object.bytes)),
          }
        : null;
    },
  };
  const env = { SYNTILA_DB: db, SYNTILA_ARTIFACTS: bucket } as never;
  async function upload(text = "hello **file**") {
    const response = await handleUploadWorkRequestFile(
      new Request(
        "https://test/api/threads/thread/work-request-files?name=note.txt&purpose=discussion",
        {
          method: "POST",
          headers: { "content-type": "text/plain" },
          body: text,
        },
      ),
      env,
      "thread",
    );
    return (
      (await response.json()) as { file: { fileId: string; sizeBytes: number } }
    ).file;
  }
  return { sqlite, env, upload, objects };
}
const request = (body: unknown, method = "POST") =>
  new Request("https://test/api/messages", {
    method,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
beforeEach(() => authorize.mockClear());

describe("Thread attachments", () => {
  it("accepts exactly 10 MiB per file and rejects larger declared uploads", async () => {
    const f = fixture();
    try {
      const size = 10 * 1024 * 1024;
      const response = await handleUploadWorkRequestFile(
        new Request("https://test?name=boundary.bin", {
          method: "POST",
          headers: { "content-length": String(size) },
          body: new Uint8Array(size),
        }),
        f.env,
        "thread",
      );
      expect(response.status).toBe(201);
      const { file } = (await response.json()) as {
        file: { sizeBytes: number };
      };
      expect(file.sizeBytes).toBe(size);
      await expect(
        handleUploadWorkRequestFile(
          new Request("https://test", {
            method: "POST",
            headers: { "content-length": String(size + 24 * 1024 + 1) },
            body: "small",
          }),
          f.env,
          "thread",
        ),
      ).rejects.toThrow("10 MB");
    } finally {
      f.sqlite.close();
    }
  });

  it("accepts a file-only human message, retains previews through history and edits, and downloads the original", async () => {
    const f = fixture();
    try {
      const file = await f.upload();
      expect(authorize.mock.calls[0]?.[3]).toBe("discuss");
      await expect(
        handleDownloadThreadFile(
          new Request("https://test"),
          f.env,
          "thread",
          file.fileId,
        ),
      ).rejects.toThrow("File not found");
      const response = await handleCreateDiscussionMessage(
        request({
          body: "",
          attachments: [{ kind: "file", ...file, previewText: "forged" }],
        }),
        f.env,
        "thread",
      );
      const { message } = (await response.json()) as {
        message: {
          id: string;
          body: string;
          attachments: { previewText: string; name: string }[];
        };
      };
      expect(message.body).toBe("");
      expect(message.attachments[0]).toMatchObject({
        name: "note.txt",
        previewText: "hello **file**",
      });
      const edited = await handleEditDiscussionMessage(
        request({ body: "new caption" }, "PATCH"),
        f.env,
        message.id,
      );
      expect(
        ((await edited.json()) as { message: { attachments: unknown } }).message
          .attachments,
      ).toEqual(message.attachments);
      const history = await handleListDiscussionMessages(
        new Request("https://test"),
        f.env,
        "thread",
      );
      expect(
        ((await history.json()) as { messages: { attachments: unknown }[] })
          .messages[0]?.attachments,
      ).toEqual(message.attachments);
      const download = await handleDownloadThreadFile(
        new Request("https://test"),
        f.env,
        "thread",
        file.fileId,
      );
      expect(await download.text()).toBe("hello **file**");
      expect(download.headers.get("cache-control")).toBe("private, no-store");
      await expect(
        handleDownloadThreadFile(
          new Request("https://test"),
          f.env,
          "other-thread",
          file.fileId,
        ),
      ).rejects.toThrow("File not found");
      await expect(
        normalizeDiscussionAttachments(
          f.env,
          [{ kind: "file", ...file }],
          "other-thread",
          "owner",
        ),
      ).rejects.toThrow("not found");
      await expect(
        normalizeDiscussionAttachments(
          f.env,
          [{ kind: "file", ...file }],
          "thread",
          "other-user",
        ),
      ).rejects.toThrow("not found");
    } finally {
      f.sqlite.close();
    }
  });
  it("stores image previews once and rejects oversized or non-JPEG preview payloads", async () => {
    const f = fixture();
    try {
      const form = new FormData();
      form.set("file", new Blob(["original"]), "photo.png");
      form.set("mediaType", "image/png");
      form.set("previewImage", "/9j/AAAA");
      const response = await handleUploadWorkRequestFile(
        new Request("https://test?name=photo.png&purpose=discussion", {
          method: "POST",
          body: form,
        }),
        f.env,
        "thread",
      );
      const { file } = (await response.json()) as {
        file: { fileId: string; sizeBytes: number };
      };
      const normalized = await normalizeDiscussionAttachments(
        f.env,
        [{ kind: "file", ...file }],
        "thread",
        "owner",
      );
      expect(normalized[0]).toMatchObject({ previewImage: "/9j/AAAA" });
      expect(f.objects.size).toBe(2);
      for (const preview of ["<svg>unsafe</svg>", "/9j/" + "A".repeat(32000)]) {
        form.set("previewImage", preview);
        await expect(
          handleUploadWorkRequestFile(
            new Request("https://test", { method: "POST", body: form }),
            f.env,
            "thread",
          ),
        ).rejects.toThrow("Invalid image preview");
      }
      expect(f.objects.size).toBe(2);
    } finally {
      f.sqlite.close();
    }
  });
  it("bounds text previews, rejects invalid references, and requires either a message or file", async () => {
    expect(
      fileTextPreview(
        "a.txt",
        "text/plain",
        new TextEncoder().encode("a".repeat(2000)).buffer,
      ),
    ).toHaveLength(1200);
    expect(
      fileTextPreview("a.pdf", "application/pdf", new ArrayBuffer(0)),
    ).toBeUndefined();
    const f = fixture();
    try {
      await expect(
        handleCreateDiscussionMessage(request({ body: "" }), f.env, "thread"),
      ).rejects.toThrow();
      await expect(
        normalizeDiscussionAttachments(
          f.env,
          Array(11).fill({}),
          "thread",
          "owner",
        ),
      ).rejects.toThrow("10");
      await expect(
        normalizeDiscussionAttachments(
          f.env,
          [{ kind: "file", fileId: "../secret" }],
          "thread",
          "owner",
        ),
      ).rejects.toThrow("Invalid attachment");
      await expect(
        handleUploadWorkRequestFile(
          new Request("https://test", {
            method: "POST",
            body: new Uint8Array(10 * 1024 * 1024 + 1),
          }),
          f.env,
          "thread",
        ),
      ).rejects.toThrow("10 MB");
    } finally {
      f.sqlite.close();
    }
  });
});
