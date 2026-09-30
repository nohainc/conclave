import assert from "node:assert/strict";
import { createPrivateKey, createPublicKey, verify } from "node:crypto";
import { gunzipSync } from "node:zlib";
import test from "node:test";

import {
  canonicalJson,
  digestPackage,
  makeArchive,
  signManifest,
  tarEntry,
} from "./publish-worker-releases.mjs";

test("canonical JSON sorts object keys recursively and preserves list order", () => {
  assert.equal(
    canonicalJson({ z: 1, nested: { b: true, a: "x" }, list: [2, 1] }),
    '{"list":[2,1],"nested":{"a":"x","b":true},"z":1}',
  );
});

test("package digest matches the Worker directory digest framing", () => {
  const contents = Buffer.from("worker binary");
  assert.equal(
    digestPackage("bin/conclave-worker", 0o755, contents).length,
    64,
  );
  assert.notEqual(
    digestPackage("bin/conclave-worker", 0o755, contents),
    digestPackage("bin/conclave-worker", 0o777, contents),
  );
});

test("tar.gz archive is deterministic and contains a valid executable entry", () => {
  const binary = Buffer.from("native executable bytes");
  const first = makeArchive(binary, 0o755);
  const second = makeArchive(binary, 0o755);
  assert.deepEqual(first, second);

  const tar = gunzipSync(first);
  const header = tar.subarray(0, 512);
  assert.equal(
    header.toString("utf8", 0, 100).replace(/\0.*$/s, ""),
    "bin/conclave-worker",
  );
  assert.equal(header.toString("ascii", 100, 107), "0000755");
  const expectedChecksum = Number.parseInt(
    header.toString("ascii", 148, 154),
    8,
  );
  const checksumHeader = Buffer.from(header);
  checksumHeader.fill(0x20, 148, 156);
  assert.equal(
    [...checksumHeader].reduce((sum, byte) => sum + byte, 0),
    expectedChecksum,
  );
  assert.deepEqual(tar.subarray(512, 512 + binary.length), binary);
});

test("Ed25519 manifest signature is reproducible for the same seed and payload", () => {
  const seed = Buffer.alloc(32, 7).toString("base64");
  const manifest = { workerTypeId: "chatgpt", workerVersion: "1.2.3" };
  const signature = Buffer.from(signManifest(manifest, seed), "base64");
  assert.equal(signature.toString("base64"), signManifest(manifest, seed));
  const privateKey = createPrivateKey({
    key: Buffer.concat([
      Buffer.from("302e020100300506032b657004220420", "hex"),
      Buffer.from(seed, "base64"),
    ]),
    format: "der",
    type: "pkcs8",
  });
  const publicDer = createPublicKey(privateKey).export({
    format: "der",
    type: "spki",
  });
  assert.equal(
    verify(
      null,
      Buffer.from(
        `conclave-worker-release-manifest-v2\n${canonicalJson(manifest)}`,
      ),
      createPublicKey({ key: publicDer, format: "der", type: "spki" }),
      signature,
    ),
    true,
  );
  assert.notEqual(
    signature.toString("base64"),
    signManifest({ ...manifest, workerVersion: "1.2.4" }, seed),
  );
});

test("tar entry writes a complete header for an empty file", () => {
  assert.equal(tarEntry("bin/worker", Buffer.alloc(0), 0o755).length, 512);
});
