import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import type { ChildProcess } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { Browser } from "../src/browser.ts";
import { startSandbox, type Sandbox } from "../src/sandbox.ts";
import { appUrl, startWeb, waitForWeb } from "../src/web.ts";

/**
 * The PWA end to end: a real browser, the dev server, the real daemon, the
 * stub pi. Slower than the rest and needs Chrome, so it runs on its own with
 * `pnpm test:browser` rather than in `pnpm test`.
 */

const WEB_PORT = Number(process.env.PIOS_SMOKE_WEB_PORT ?? 5189);
const API_PORT = Number(process.env.PIOS_SMOKE_API_PORT ?? 4329);

describe("the web app against the sandbox", () => {
  let sandbox: Sandbox;
  let web: ChildProcess;
  let browser: Browser;

  before(async () => {
    sandbox = await startSandbox({ scenario: "files", port: API_PORT });
    web = startWeb(sandbox.baseUrl, WEB_PORT, "ignore");
    await waitForWeb(WEB_PORT);
    browser = await Browser.launch();
    await browser.goto(appUrl(sandbox, WEB_PORT));
    await browser.waitFor("#root *");
    await until(() => browser.tapText("editor"), "the scenario's session to be listed");
    await browser.waitFor("textarea");
  });

  after(async () => {
    await browser?.close();
    web?.kill();
    await sandbox?.close();
  });

  async function send(text: string): Promise<void> {
    assert.ok(await browser.type("textarea", text));
    assert.ok(await browser.tap('button[aria-label="send"]'));
  }

  async function until(check: () => Promise<boolean>, what: string, timeoutMs = 10_000): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (await check()) return;
      await browser.sleep(100);
    }
    assert.fail(`timed out waiting for ${what}`);
  }

  const shows = (text: string) => async () => (await browser.text(".chat")).includes(text);

  it("sends a prompt and shows the answer", async () => {
    await send("hello from the smoke test");
    await until(shows("echo: hello from the smoke test"), "the echo");
  });

  /** Hands files to a file input the way a picker would. */
  async function pick(selector: string, name: string, body: string): Promise<void> {
    const picked = await browser.eval<boolean>(`(() => {
      const input = document.querySelector(${JSON.stringify(selector)});
      if (!input) return false;
      const transfer = new DataTransfer();
      transfer.items.add(new File([${JSON.stringify(body)}], ${JSON.stringify(name)}, { type: "text/plain" }));
      input.files = transfer.files;
      input.dispatchEvent(new Event("change", { bubbles: true }));
      return true;
    })()`);
    assert.ok(picked, `no ${selector}`);
  }

  const cwd = () => sandbox.server.registry.get("sbx-files")!.info.cwd;

  it("attaches a file to a prompt as a path in the project", async () => {
    await pick('.composer .attach input', "brief.txt", "from the phone");
    await until(
      async () => (await browser.text(".composer .file-chip")).includes("brief.txt") &&
        !(await browser.text(".composer .file-chip")).includes("uploading"),
      "the upload to finish",
    );
    await send("read this");
    await until(shows(".pios-uploads/brief.txt"), "the path in the prompt");
    assert.equal(readFileSync(join(cwd(), ".pios-uploads", "brief.txt"), "utf8"), "from the phone");
  });

  it("uploads into the folder the file tree is showing", async () => {
    assert.ok(await browser.tap('button[aria-label="session menu"]'));
    assert.ok(await browser.tap(".menu-popover .list-row"));
    await until(async () => (await browser.text(".file-list")).includes("README.md"), "the tree");
    await pick('.file-view .attach input', "README.md", "uploaded");
    await until(
      async () => (await browser.text(".file-list")).includes("README (2).md"),
      "the renamed upload to be listed",
    );
    assert.equal(readFileSync(join(cwd(), "README (2).md"), "utf8"), "uploaded");
    assert.notEqual(readFileSync(join(cwd(), "README.md"), "utf8"), "uploaded");
    assert.ok(await browser.tap('.file-view button[aria-label="back to chat"]'));
    await browser.waitFor(".chat");
  });

  it("names the session with /name", async () => {
    await send("/name smoke session");
    await until(
      async () => (await browser.text(".chat-header")).includes("smoke session"),
      "the header to carry the new name",
    );
  });

  it("compacts with /compact and marks where", async () => {
    await send("/compact");
    await until(shows("Context compacted"), "the compaction divider");
  });

  it("copies the last answer with /copy", async () => {
    await send("/copy");
    await until(shows("the last answer"), "the copy notice");
  });

  it("shows the session's accounting with /session", async () => {
    await send("/session");
    await until(shows("2,400 total"), "the token count");
    assert.ok(await browser.tap('.dialog button[aria-label="cancel"]'));
    await browser.waitFor("textarea");
  });

  it("exports with /export and reloads with /reload", async () => {
    await send("/export");
    await until(shows("Exported to"), "the export notice");
    await send("/reload");
    await browser.sleep(500);
    assert.ok(!(await browser.text("body")).includes("Rejected"), "the reload was accepted");
  });

  it("opens git full screen and keeps a commit message across leaving it", async () => {
    const openGit = () => browser.tap('.chat-header button[aria-label^="git"]');
    const message = () => browser.eval<string | null>(`document.querySelector(".git-message")?.value ?? null`);

    assert.ok(await openGit());
    await until(async () => (await browser.text(".git-view")).includes("Stashes"), "the git view");
    assert.equal(await browser.eval(`document.querySelector(".chat") === null`), true, "the chat is replaced");

    assert.ok(await browser.type(".git-message", "smoke: keep me"));
    assert.ok(await browser.tapText("History"));
    assert.ok(await browser.tapText("Changes"));
    assert.equal(await message(), "smoke: keep me");

    assert.ok(await browser.tap('.git-view button[aria-label="back to chat"]'));
    await browser.waitFor(".chat");
    assert.ok(await openGit());
    await until(async () => (await message()) === "smoke: keep me", "the message to survive");
    assert.ok(await browser.tap('.git-view button[aria-label="back to chat"]'));
    await browser.waitFor(".chat");
  });

  it("hides dotfiles in the file tree when asked to", async () => {
    const tree = () => browser.text(".file-list");
    assert.ok(await browser.tap('button[aria-label="session menu"]'));
    assert.ok(await browser.tap(".menu-popover .list-row"));
    await until(async () => (await tree()).includes(".git"), "the tree to list .git");

    assert.ok(await browser.tap('.file-view .check input'));
    await until(async () => !(await tree()).includes(".git"), ".git to be hidden");
    assert.ok((await tree()).includes("README.md"), "other entries stay");

    assert.ok(await browser.tap('.file-view .check input'));
    await until(async () => (await tree()).includes(".git"), ".git to come back");
    assert.ok(await browser.tap('.file-view button[aria-label="back to chat"]'));
    await browser.waitFor(".chat");
  });

  it("keeps an open editor through a streaming turn", async () => {
    assert.ok(await browser.tap('button[aria-label="session menu"]'));
    assert.ok(await browser.tap(".menu-popover .list-row"));
    await until(() => browser.tapText("README.md"), "the file tree");
    await until(() => browser.tapText("Edit"), "the editor");
    await browser.eval(`(document.querySelector(".cm-editor").dataset.smoke = "1", true)`);

    const live = sandbox.server.registry.get("sbx-files")!;
    await live.prompt("streaming while the editor is open");
    await browser.sleep(1500);

    assert.equal(
      await browser.eval(`document.querySelector(".cm-editor")?.dataset.smoke ?? null`),
      "1",
      "the editor was not rebuilt underneath the reader",
    );
  });
});
