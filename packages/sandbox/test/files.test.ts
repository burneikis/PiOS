import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import { startSandbox, type Sandbox } from "../src/sandbox.ts";

/** The editor's routes against real files in the sandbox's temp project. */
describe("file editing", () => {
  let sandbox: Sandbox;
  const auth = () => ({ authorization: `Bearer ${sandbox.deviceToken}` });

  before(async () => {
    sandbox = await startSandbox({ scenario: "files" });
  });
  after(async () => {
    await sandbox.close();
  });

  const file = (path: string, extra = "") =>
    `${sandbox.baseUrl}/file?session=sbx-files&path=${encodeURIComponent(path)}${extra}`;

  const load = async (path: string) =>
    (await (await fetch(file(path, "&text=1"), { headers: auth() })).json()) as {
      text: string;
      etag: string;
      editable: boolean;
      eol: "lf" | "crlf";
      trailingNewline: boolean;
      reason?: string;
    };

  it("browses the project tree", async () => {
    const response = await fetch(`${sandbox.baseUrl}/dirs?session=sbx-files&files=1`, {
      headers: auth(),
    });
    const listing = (await response.json()) as { entries: { name: string; dir: boolean }[] };
    const names = listing.entries.map((e) => e.name);
    assert.deepEqual(names.slice(0, 2), [".git", "src"], "directories first, nothing hidden");
    assert.ok(listing.entries.some((e) => e.name === "README.md" && !e.dir));
  });

  it("opens a file and saves it back", async () => {
    const loaded = await load("src/index.ts");
    assert.equal(loaded.editable, true);

    const edited = loaded.text.replace("return 1", "return 2");
    const saved = await fetch(file("src/index.ts"), {
      method: "PUT",
      headers: { ...auth(), "if-match": loaded.etag },
      body: edited,
    });
    assert.equal(saved.status, 200);
    assert.equal(
      readFileSync(join(sandbox.sessions[0]!.cwd, "src/index.ts"), "utf8"),
      edited,
    );
  });

  it("refuses a save when something else wrote the file first", async () => {
    const loaded = await load("README.md");
    writeFileSync(join(sandbox.sessions[0]!.cwd, "README.md"), "# rewritten by the agent\n");

    const conflict = await fetch(file("README.md"), {
      method: "PUT",
      headers: { ...auth(), "if-match": loaded.etag },
      body: "# mine\n",
    });
    assert.equal(conflict.status, 409);

    // "Overwrite" in the UI: the user saw the warning and chose their version.
    const forced = await fetch(file("README.md"), {
      method: "PUT",
      headers: { ...auth(), "if-match": "*" },
      body: "# mine\n",
    });
    assert.equal(forced.status, 200);
  });

  it("degrades to a preview for files it cannot edit", async () => {
    assert.equal((await load("big.txt")).reason, "too_large");
    assert.equal((await load("image.bin")).reason, "binary");
    assert.equal((await load("bundle.min.js")).reason, "long_lines");
    assert.ok((await load("big.txt")).text.length > 0);
  });

  it("keeps CRLF and the absent trailing newline", async () => {
    const loaded = await load("notes.txt");
    assert.equal(loaded.eol, "crlf");
    assert.equal(loaded.trailingNewline, false);

    await fetch(file("notes.txt", "&eol=crlf&nl=0"), {
      method: "PUT",
      headers: { ...auth(), "if-match": loaded.etag },
      body: loaded.text.replace("line two", "line 2"),
    });
    assert.equal(
      readFileSync(join(sandbox.sessions[0]!.cwd, "notes.txt"), "utf8"),
      "line one\r\nline 2\r\nno trailing newline",
    );
  });
});
