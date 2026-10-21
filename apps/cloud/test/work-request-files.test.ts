import { describe, expect, it } from "vitest";
import {
  hydrateWorkRequestFiles,
  workRequestFileMetadata,
  isWorkRequestFileId,
  verifyWorkRequestFile,
  workRequestFileKey,
} from "../src/routes/work-request-files.js";

const fileId = "wrf-11111111-2222-3333-4444-555555555555";

function bucketWith(bytes: Uint8Array, customMetadata: Record<string, string>) {
  const object = {
    size: bytes.byteLength,
    customMetadata,
    arrayBuffer: async () => bytes.buffer.slice(0),
  };
  const keys: string[] = [];
  return {
    keys,
    bucket: {
      head: async (key: string) => (keys.push(key), object),
      get: async (key: string) => (keys.push(key), object),
    } as unknown as R2Bucket,
  };
}

describe("Work Request files", () => {
  it("projects historical file metadata without bytes or storage identifiers", () => {
    expect(
      workRequestFileMetadata({
        attachments: [
          {
            kind: "file",
            name: "photo.jpg",
            sizeBytes: 1234,
            fileId,
            contentBase64: "private-bytes",
            mediaType: "image/jpeg",
          },
          { kind: "url", url: "https://example.com" },
          null,
        ],
      }),
    ).toEqual([{ kind: "file", name: "photo.jpg", sizeBytes: 1234 }]);
    expect(workRequestFileMetadata({})).toEqual([]);
  });

  it("accepts only generated file ids", () => {
    expect(isWorkRequestFileId(fileId)).toBe(true);
    expect(isWorkRequestFileId("../secret")).toBe(false);
  });

  it("verifies owner, Thread and size, with no total limit", async () => {
    const { bucket } = bucketWith(new Uint8Array(2 * 1024 * 1024), {
      threadId: "thread-1",
      userId: "user-1",
      digest: "sha256:x",
    });
    const env = { CONCLAVE_ARTIFACTS: bucket } as never;
    const size = 2 * 1024 * 1024;
    await expect(
      verifyWorkRequestFile(env, fileId, "thread-1", "user-1", size),
    ).resolves.toEqual({ digest: "sha256:x" });
    await expect(
      verifyWorkRequestFile(env, fileId, "thread-2", "user-1", size),
    ).rejects.toThrow("not found");
    await expect(
      verifyWorkRequestFile(env, fileId, "thread-1", "user-2", size),
    ).rejects.toThrow("not found");
    await expect(
      verifyWorkRequestFile(env, fileId, "thread-1", "user-1", size - 1),
    ).rejects.toThrow("not found");
  });

  it("adds file bytes to the outgoing assignment payload only", async () => {
    const { bucket, keys } = bucketWith(new TextEncoder().encode("hello"), {
      threadId: "thread-1",
    });
    const payload = {
      threadId: "thread-1",
      input: {
        attachments: [
          { kind: "file", name: "a.txt", sizeBytes: 5, fileId },
          { kind: "url", name: "link", url: "https://example.com/" },
        ],
      },
    };
    const result = (await hydrateWorkRequestFiles(
      { CONCLAVE_ARTIFACTS: bucket },
      payload,
    )) as typeof payload;
    expect(keys).toEqual([workRequestFileKey(fileId)]);
    expect(result.input.attachments[0]).toMatchObject({
      contentBase64: btoa("hello"),
    });
    expect(payload.input.attachments[0]).not.toHaveProperty("contentBase64");
  });

  it("rejects delivery when a file belongs to another Thread", async () => {
    const { bucket } = bucketWith(new Uint8Array(5), { threadId: "other" });
    await expect(
      hydrateWorkRequestFiles(
        { CONCLAVE_ARTIFACTS: bucket },
        {
          threadId: "thread-1",
          input: { attachments: [{ kind: "file", sizeBytes: 5, fileId }] },
        },
      ),
    ).rejects.toThrow("unavailable");
  });
});
