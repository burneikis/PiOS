import assert from "node:assert/strict";
import { mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { NotificationInbox } from "../src/inbox.ts";

const dirs: string[] = [];
after(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

function storePath(): string {
  const dir = mkdtempSync(join(tmpdir(), "pios-inbox-"));
  dirs.push(dir);
  return join(dir, "inbox.json");
}

const message = (sessionId: string, body: string) => ({
  title: "t",
  body,
  url: `/?session=${sessionId}`,
  tag: `session:${sessionId}`,
});

test("only opted-in devices get anything, and not those skipped", () => {
  const inbox = new NotificationInbox(storePath());
  inbox.setEnabled("a", true);
  inbox.setEnabled("b", true);
  assert.deepEqual(inbox.recipients(new Set(["b"])), ["a"]);
  const added = inbox.add("s1", message("s1", "done"), ["a", "c"]);
  assert.deepEqual([...added.keys()], ["a"]);
  assert.equal(inbox.pending("a").length, 1);
  assert.equal(inbox.pending("c").length, 0);
});

test("a later settle replaces an unread one for the same session", () => {
  const inbox = new NotificationInbox(storePath());
  inbox.setEnabled("a", true);
  inbox.add("s1", message("s1", "first"), ["a"]);
  inbox.add("s2", message("s2", "other"), ["a"]);
  inbox.add("s1", message("s1", "second"), ["a"]);
  assert.deepEqual(inbox.pending("a").map((p) => p.body), ["other", "second"]);
});

test("items stay until acknowledged, across restarts", () => {
  const path = storePath();
  const inbox = new NotificationInbox(path);
  inbox.setEnabled("a", true);
  const item = inbox.add("s1", message("s1", "done"), ["a"]).get("a")!;
  const reopened = new NotificationInbox(path);
  assert.equal(reopened.pending("a")[0]?.id, item.id);
  reopened.acknowledge("a", [item.id]);
  assert.equal(new NotificationInbox(path).pending("a").length, 0);
});

test("stale items expire and opting out drops the queue", () => {
  const inbox = new NotificationInbox(storePath());
  inbox.setEnabled("a", true);
  inbox.add("s1", message("s1", "old"), ["a"], 0);
  assert.equal(inbox.pending("a", 25 * 60 * 60 * 1000).length, 0);
  inbox.add("s2", message("s2", "new"), ["a"]);
  inbox.removeDevice("a");
  assert.equal(inbox.enabled("a"), false);
  assert.equal(inbox.pending("a").length, 0);
});

test("the store is not world readable", () => {
  const path = storePath();
  new NotificationInbox(path).setEnabled("a", true);
  assert.equal(statSync(path).mode & 0o077, 0);
});
