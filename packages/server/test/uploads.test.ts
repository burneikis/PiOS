import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, utimesSync, writeFileSync } from "node:fs";
import type { IncomingMessage } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough, Readable } from "node:stream";
import { prepareUploadDir, receiveUpload, UPLOAD_KEEP_MS } from "../src/uploads.ts";
import { openSession, startHarness } from "./helpers.ts";

const body = (...chunks: string[]) => Readable.from(chunks.map((c) => Buffer.from(c))) as IncomingMessage;

function repo(): string {
  const dir = mkdtempSync(join(tmpdir(), "pios-uploads-"));
  execFileSync("git", ["init", "--quiet"], { cwd: dir });
  return dir;
}

test("the attachment folder is excluded from git once, and stays untracked", async () => {
  const dir = repo();
  writeFileSync(join(dir, ".git", "info", "exclude"), "# existing\n*.log");
  await prepareUploadDir(dir);
  await prepareUploadDir(dir);

  const exclude = readFileSync(join(dir, ".git", "info", "exclude"), "utf8");
  assert.equal(exclude, "# existing\n*.log\n.pios-uploads/\n");
  writeFileSync(join(dir, ".pios-uploads", "a.txt"), "x");
  const status = execFileSync("git", ["status", "--porcelain"], { cwd: dir, encoding: "utf8" });
  assert.equal(status, "");
  assert.ok(!existsSync(join(dir, ".gitignore")), "tracked files are left alone");
});

test("a project without git still gets the folder", async () => {
  const dir = mkdtempSync(join(tmpdir(), "pios-uploads-nogit-"));
  const uploads = await prepareUploadDir(dir);
  assert.ok(existsSync(uploads));
});

test("old attachments are dropped, recent ones and folders are kept", async () => {
  const dir = mkdtempSync(join(tmpdir(), "pios-uploads-prune-"));
  const uploads = join(dir, ".pios-uploads");
  mkdirSync(join(uploads, "kept-dir"), { recursive: true });
  writeFileSync(join(uploads, "old.txt"), "x");
  writeFileSync(join(uploads, "new.txt"), "x");
  const now = Date.now();
  const old = new Date(now - UPLOAD_KEEP_MS - 60_000);
  utimesSync(join(uploads, "old.txt"), old, old);
  utimesSync(join(uploads, "kept-dir"), old, old);

  await prepareUploadDir(dir, now);
  assert.ok(!existsSync(join(uploads, "old.txt")));
  assert.ok(existsSync(join(uploads, "new.txt")));
  assert.ok(existsSync(join(uploads, "kept-dir")));
});

test("an upload is streamed to its name and leaves no temp file behind", async () => {
  const dir = mkdtempSync(join(tmpdir(), "pios-receive-"));
  writeFileSync(join(dir, "a.txt"), "original");
  const outcome = await receiveUpload(body("new ", "bytes"), dir, "a.txt", 1024);
  assert.deepEqual(outcome, { ok: true, path: join(dir, "a (2).txt"), bytes: 9 });
  assert.equal(readFileSync(join(dir, "a.txt"), "utf8"), "original");
  assert.equal(readFileSync(join(dir, "a (2).txt"), "utf8"), "new bytes");
  assert.deepEqual(readdirSync(dir).sort(), ["a (2).txt", "a.txt"]);
});

test("a body past the limit is refused whatever it declared, and cleaned up", async () => {
  const dir = mkdtempSync(join(tmpdir(), "pios-receive-"));
  const outcome = await receiveUpload(body("12345", "67890"), dir, "big.bin", 8);
  assert.deepEqual(outcome, { ok: false, error: "too_large" });
  assert.deepEqual(readdirSync(dir), []);
});

test("a dropped connection leaves nothing that looks complete", async () => {
  const dir = mkdtempSync(join(tmpdir(), "pios-receive-"));
  const stream = new PassThrough();
  const pending = receiveUpload(stream as unknown as IncomingMessage, dir, "half.bin", 1024);
  stream.write("half");
  stream.destroy(new Error("ECONNRESET"));
  assert.deepEqual(await pending, { ok: false, error: "aborted" });
  assert.deepEqual(readdirSync(dir), []);
});

test("a disk failure is raised, not mistaken for a client that left", async (t) => {
  if (process.getuid?.() === 0) return t.skip("root ignores directory permissions");
  const dir = mkdtempSync(join(tmpdir(), "pios-receive-"));
  chmodSync(dir, 0o500);
  try {
    await assert.rejects(receiveUpload(body("x"), dir, "a.txt", 1024), { code: "EACCES" });
  } finally {
    chmodSync(dir, 0o700);
  }
});

test("an oversized upload is answered with 413 before it is read", async () => {
  const harness = await startHarness(undefined, { maxUploadBytes: 1024 });
  try {
    const cwd = join(harness.dir, "project");
    mkdirSync(cwd, { recursive: true });
    const session = await openSession(harness, cwd);
    const res = await fetch(`${harness.baseUrl}/upload?session=${session}&name=big.bin`, {
      method: "POST",
      headers: { authorization: `Bearer ${harness.deviceToken}` },
      body: Buffer.alloc(64 * 1024),
    });
    assert.equal(res.status, 413);
    assert.deepEqual(await res.json(), { error: "too_large" });
    assert.ok(!existsSync(join(cwd, ".pios-uploads", "big.bin")));
  } finally {
    await harness.close();
  }
});
