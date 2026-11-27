import { PreviewAutomationEvaluateInput } from "@t3tools/contracts";
import * as Schema from "effect/Schema";
import {
  chromium,
  type Browser,
  type BrowserContext,
  type CDPSession,
  type Page,
} from "playwright-core";
import {
  afterAll,
  afterEach,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vite-plus/test";

import * as ServerBrowserPage from "./ServerBrowserPage.ts";
import { SessionControl } from "./SessionControl.ts";

const decodeEvaluateInput = Schema.decodeUnknownSync(PreviewAutomationEvaluateInput);

describe("snapshot deadline diagnostics", () => {
  const never = () => new Promise<never>(() => {});
  const stalledSnapshot = async (options: {
    readonly stalled?: "metrics";
    readonly page?: Partial<Record<keyof Page, unknown>>;
    readonly advanceMs: number;
  }) => {
    vi.useFakeTimers();
    try {
      // Snapshots list extension frames by url, so each stub frame needs one.
      const frame = { url: () => "about:blank" };
      const page = {
        viewportSize: () => ({ width: 1280, height: 800 }),
        mainFrame: () => frame,
        frames: () => [frame],
        on: () => {},
        evaluate: async () => ({
          url: "about:blank",
          title: "",
          loading: false,
          visibleText: "",
          interactiveElements: [],
        }),
        ariaSnapshot: async () => "",
        ...options.page,
      } as unknown as Page;
      const cdp = {
        send: async (method: string) => {
          if (options.stalled === "metrics") return never();
          if (method === "Page.captureScreenshot") return { data: "" };
          if (method === "Page.getFrameTree") return { frameTree: { frame: { id: "main" } } };
          if (method === "Page.createIsolatedWorld") return { executionContextId: 1 };
          if (method === "Runtime.evaluate") return { result: { value: [] } };
          throw new Error(`Unexpected command: ${method}`);
        },
      } as unknown as CDPSession;
      const captured = ServerBrowserPage.snapshot({
        page,
        cdp,
        includeImage: true,
        renderScale: options.stalled === "metrics" ? "display" : 1,
        consoleEntries: [],
        networkEntries: [],
        actionTimeline: [],
      }).catch((error: unknown) => error);
      await vi.advanceTimersByTimeAsync(options.advanceMs);
      return await captured;
    } finally {
      vi.useRealTimers();
    }
  };

  it("identifies a stalled metrics read", async () => {
    expect(await stalledSnapshot({ stalled: "metrics", advanceMs: 10_000 })).toMatchObject({
      tag: "PreviewAutomationTimeoutError",
      detail: { timeoutMs: 10_000, pendingStages: ["metrics"] },
    });
  });

  it("keeps an accessibility tree that hit its own timeout", async () => {
    const timedOut = Object.assign(new Error("Timeout exceeded"), { name: "TimeoutError" });
    const captured = await stalledSnapshot({
      page: { ariaSnapshot: () => Promise.reject(timedOut) },
      advanceMs: 0,
    });
    expect(captured).toMatchObject({
      tag: "PreviewAutomationTimeoutError",
      detail: { timeoutMs: 10_000 },
    });
    expect((captured as ServerBrowserPage.ServerBrowserOperationError).detail).toMatchObject({
      pendingStages: expect.arrayContaining(["accessibility tree"]),
    });
  });

  it("omits a timed-out stage after it succeeds on retry", async () => {
    let attempts = 0;
    const timedOut = Object.assign(new Error("Timeout exceeded"), { name: "TimeoutError" });
    expect(
      await stalledSnapshot({
        page: {
          evaluate: never,
          ariaSnapshot: async () => {
            if (attempts++ === 0) throw timedOut;
            return "";
          },
        },
        advanceMs: 10_000,
      }),
    ).toMatchObject({ detail: { timeoutMs: 10_000, pendingStages: ["page state"] } });
  });

  it.each(["elementHandle", "contentFrame"] as const)(
    "identifies stalled iframe %s lookup",
    async (stage) => {
      const main = { url: () => "about:blank" };
      const child = { evaluate: never, parentFrame: () => main, url: () => "about:blank" };
      const captured = await stalledSnapshot({
        page: {
          mainFrame: () => main,
          frames: () => [main, child],
          context: () => ({
            newCDPSession: () =>
              Promise.reject(new Error("Only this preview tab's page can be attached")),
          }),
          ariaSnapshot: async () => "- iframe [ref=f1]:\n  - text: inside",
          locator: () => ({
            elementHandle:
              stage === "elementHandle" ? never : async () => ({ contentFrame: never }),
          }),
        },
        advanceMs: 10_000,
      });
      expect(captured).toMatchObject({
        detail: { timeoutMs: 10_000, pendingStages: expect.arrayContaining(["frames"]) },
      });
    },
  );

  it("reports a frame that didn't answer as the frame's own timeout", async () => {
    const main = { url: () => "about:blank" };
    // A desktop tab refuses frame sessions, so the frame is read in its own world.
    const child = { evaluate: never, parentFrame: () => main, url: () => "about:blank" };
    const captured = await stalledSnapshot({
      page: {
        mainFrame: () => main,
        frames: () => [main, child],
        context: () => ({
          newCDPSession: () =>
            Promise.reject(new Error("Only this preview tab's page can be attached")),
        }),
        ariaSnapshot: async () => "- iframe [ref=f1]:\n  - text: inside",
        locator: () => ({
          elementHandle: async () => ({ contentFrame: async () => child, dispose: async () => {} }),
        }),
      },
      // Both attempts wait out the frame; neither reaches the capture deadline.
      advanceMs: 2_000,
    });
    expect(captured).toMatchObject({
      tag: "PreviewAutomationTimeoutError",
      detail: { timeoutMs: 1_000, pendingStages: ["frames"] },
    });
  });
});

describe("server browser capture deadlines", () => {
  it("releases control after an unanswered capture and ignores its late reply", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    try {
      const captured = Promise.withResolvers<{ data: string }>();
      const send = vi.fn(async (method: string) =>
        method === "Page.captureScreenshot"
          ? captured.promise
          : { result: { value: "still responsive" } },
      );
      const cdp = { send } as unknown as CDPSession;
      const control = new SessionControl("agent");
      let outcome: unknown;
      const capture = control
        .agent("agent", () => ServerBrowserPage.captureViewport(cdp, { format: "png" }))
        .catch((cause: unknown) => {
          outcome = cause;
        });
      const evaluation = control.agent("agent", () =>
        ServerBrowserPage.evaluate(cdp, { expression: "document.title" }, 1_000),
      );

      await vi.advanceTimersByTimeAsync(3_000);
      expect(outcome).toMatchObject({
        tag: "PreviewAutomationExecutionError",
        message: expect.stringContaining("not producing screenshot frames"),
      });
      await capture;
      expect(await evaluation).toBe("still responsive");
      expect(vi.getTimerCount()).toBe(0);

      captured.resolve({ data: "late-frame" });
      await captured.promise;
      expect(outcome).toBeInstanceOf(ServerBrowserPage.ServerBrowserOperationError);
      expect(send.mock.calls.map(([method]) => method)).toEqual([
        "Page.captureScreenshot",
        "Runtime.evaluate",
      ]);
    } finally {
      vi.useRealTimers();
    }
  });
});

it("labels extension UI with page boxes, drops what its frame clips, and never shows its field values, codes or generated passwords", () => {
  // Playwright's tree of a 1Password-shaped panel, with its boxes relative to the frame.
  const frameTree = [
    '- dialog "Sign in with 1Password" [ref=f1e2] [box=0,0,360,63]:',
    "  - text: Cloudflare · max.schwenk@owner.com",
    '  - button "Sign in" [ref=f1e3] [box=236,0,57,21]',
    '  - textbox "Password" [ref=f1e6] [box=153,21,153,21]: hunter2-secret',
    '  - textbox "One-time code" [ref=f1e8] [box=64,42,153,21]: "482913"',
    "  - text: Current code 482 913",
    '  - button "Use suggested password xK7#mP2$qL9!vR4" [ref=f1e9]',
    "  - listbox [ref=f1e10] [box=8,130,340,96]:",
    '    - option "Cloudflare — gm@owner.com" [ref=f1e11] [box=8,130,340,48]',
    "    - text: below the frame",
    '  - button "Other logins" [ref=f1e12] [box=120,90,100,24]',
  ].join("\n");
  expect(
    ServerBrowserPage.extensionTree("1Password", frameTree, {
      x: 460,
      y: 8,
      width: 360,
      height: 120,
    }),
  ).toBe(
    [
      '- extension "1Password" [box=460,8,360,120]:',
      '  - dialog "Sign in with 1Password" [ref=f1e2] [box=460,8,360,63]:',
      "    - text: Cloudflare · max.schwenk@owner.com",
      '    - button "Sign in" [ref=f1e3] [box=696,8,57,21]',
      '    - textbox "Password" [ref=f1e6] [box=613,29,153,21]',
      '    - textbox "One-time code" [ref=f1e8] [box=524,50,153,21]',
      "    - text: Current code ••••••••",
      '    - button "Use suggested password ••••••••" [ref=f1e9]',
      '    - button "Other logins" [ref=f1e12] [box=580,98,100,24]',
    ].join("\n"),
  );
});

describe("server browser element refs", () => {
  let browser: Browser;
  let context: BrowserContext;
  let page: Page;
  let cdp: CDPSession;

  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });
  beforeEach(async () => {
    context = await browser.newContext();
    page = await context.newPage();
    cdp = await context.newCDPSession(page);
  });
  afterEach(async () => {
    await context.close();
  });

  const takeSnapshot = (includeImage = false, renderScale: number | "display" = 1) =>
    ServerBrowserPage.snapshot({
      page,
      cdp,
      includeImage,
      renderScale,
      consoleEntries: [],
      networkEntries: [],
      actionTimeline: [],
    });
  const locators = (tree: unknown) => {
    expect(typeof tree).toBe("string");
    return Array.from(
      String(tree).matchAll(/\[ref=([^\]]+)\]/g),
      (match) => `aria-ref=${match[1]}`,
    );
  };
  const buttonLocator = (tree: unknown, name: string) => {
    const line = String(tree)
      .split("\n")
      .find((line) => line.includes(`button "${name}"`));
    const locator = locators(line)[0];
    expect(locator).toBeDefined();
    return locator!;
  };
  const repeatedRows = `<ul>${Array.from({ length: 5 }, (_, i) => `<li>row ${i + 1}<button data-testid="delete-row" onclick="this.parentElement.remove()">delete</button></li>`).join("")}</ul>`;

  it.each([1, "display"] as const)(
    "captures PNGs only on request and keeps text-only refs usable (renderScale=%s)",
    async (renderScale) => {
      await page.setContent("<button onclick=\"this.textContent='saved'\">save</button>");
      using send = vi.spyOn(cdp, "send");
      const text = await takeSnapshot(false, renderScale);
      expect(text).not.toHaveProperty("screenshot");
      expect(send.mock.calls.map(([method]) => method)).not.toContain("Page.captureScreenshot");
      expect(send.mock.calls.map(([method]) => method)).not.toContain("Page.getLayoutMetrics");
      await ServerBrowserPage.click(page, {
        locator: buttonLocator(text.accessibilityTree, "save"),
      });
      expect(await page.locator("button").textContent()).toBe("saved");

      const image = await takeSnapshot(true, renderScale);
      expect(image.screenshot).toMatchObject({ mimeType: "image/png", width: 1280, height: 720 });
      expect(Buffer.from(image.screenshot!.data, "base64").subarray(0, 8)).toEqual(
        Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
      );
      expect(image.accessibilityTree).toContain('button "saved"');
    },
  );

  const observe = (baselineId?: string, caller = "agent-a") =>
    ServerBrowserPage.observe(
      {
        page,
        cdp,
        includeImage: false,
        renderScale: 1,
        consoleEntries: [],
        networkEntries: [],
        actionTimeline: [],
      },
      caller,
      baselineId,
    );

  it("drops pixel boxes and zero-area elements from compact observations", async () => {
    await page.setContent(
      '<button>open</button><div role="alert" style="position:absolute;width:1px;height:1px;overflow:hidden">loading…</div>',
    );
    const view = await ServerBrowserPage.observe(
      {
        page,
        cdp,
        includeImage: false,
        renderScale: 1,
        consoleEntries: [],
        networkEntries: [],
        actionTimeline: [],
      },
      "agent-compact",
      undefined,
      16_000,
      true,
    );
    if (view.mode !== "full") throw new Error("Expected a full observation");
    expect(view.tree).toContain('button "open"');
    expect(view.tree).not.toContain("loading");
    expect(view.tree).not.toContain("[box=");
  });

  it("returns reconstructable changes with fresh refs and a full view after takeover", async () => {
    await page.setContent(repeatedRows);
    const first = await observe();
    expect(first.mode).toBe("full");
    if (first.mode !== "full") throw new Error("Expected initial full observation");
    await page
      .locator("li")
      .last()
      .evaluate((element) => {
        element.firstChild!.textContent = "changed";
      });
    const next = await observe(first.revision);
    expect(next.mode).toBe("delta");
    if (next.mode !== "delta") throw new Error("Expected delta");
    const lines = first.tree.split("\n");
    lines.splice(next.patch.startLine, next.patch.deleteCount, ...next.patch.lines);
    expect(lines.join("\n")).toContain("changed");
    const ref = /\[ref=([^\]]+)\]/.exec(first.tree)![1];
    await expect(
      ServerBrowserPage.click(page, { locator: `aria-ref=${first.refPrefix}${ref}` }),
    ).rejects.toThrow("stale");
    const buttonRef = /button "delete" \[ref=([^\]]+)\]/.exec(lines.join("\n"))![1];
    await ServerBrowserPage.click(page, { locator: `aria-ref=${next.refPrefix}${buttonRef}` });
    expect(await page.locator("li").count()).toBe(4);
    ServerBrowserPage.invalidateRefs(page);
    expect((await observe(next.revision)).mode).toBe("full");
  });

  it("requires the caller's explicit current baseline and resets across navigation", async () => {
    await page.setContent(repeatedRows);
    const first = await observe();
    expect((await observe(first.revision, "agent-b")).mode).toBe("full");
    expect((await observe()).mode).toBe("full");
    expect((await observe(first.revision)).mode).toBe("full");
    const current = await observe();
    await page.goto("data:text/html,<button>new document</button>");
    expect((await observe(current.revision)).mode).toBe("full");
  });

  it("bounds readiness on a changing page and reports quiet after mutations stop", async () => {
    await page.setContent(`<p>loading</p><script>
      let count = 0;
      window.changes = setInterval(() => document.querySelector('p').textContent = String(++count), 20);
    </script>`);
    const busy = await observe();
    expect(busy.readiness).toBe("budget_exhausted");
    await page.evaluate(
      "clearInterval(window.changes); document.querySelector('p').textContent = 'ready'",
    );
    const ready = await observe();
    expect(ready.readiness).toBe("dom_quiet");
    expect(ready.mode === "full" && ready.tree).toContain("ready");
  });

  it("bounds the emitted baseline without leaking password values", async () => {
    await page.setContent(
      `<input type="password" value="private-value"><p>${"😀".repeat(6000)}</p><button>save</button>`,
    );
    const first = await observe();
    expect(first.mode).toBe("full");
    if (first.mode !== "full") throw new Error("Expected full observation");
    expect(Buffer.byteLength(first.tree)).toBeLessThanOrEqual(16_000);
    expect(first.truncated).toBe(true);
    expect(JSON.stringify(first)).not.toContain("private-value");
  });

  it("clicks the fifth repeated delete control without touching row one", async () => {
    await page.setContent(repeatedRows);
    const result = await takeSnapshot();
    const buttons = String(result.accessibilityTree)
      .split("\n")
      .filter((line) => line.includes('button "delete"'));
    expect(buttons).toHaveLength(5);
    await ServerBrowserPage.click(page, { locator: locators(buttons[4])[0]!, timeoutMs: 1_000 });
    expect(await page.locator("li").allTextContents()).toEqual([
      "row 1delete",
      "row 2delete",
      "row 3delete",
      "row 4delete",
    ]);
  });

  it("returns from a click once it opens a dialog", async () => {
    await page.setContent(
      `<button onclick="document.body.dataset.answer = String(confirm('sure?'))">Confirm</button>`,
    );
    const dialog = new Promise<import("playwright-core").Dialog>((resolve) =>
      page.once("dialog", resolve),
    );
    await ServerBrowserPage.click(page, {
      locator: buttonLocator((await takeSnapshot()).accessibilityTree, "Confirm"),
      timeoutMs: 1_000,
    });
    await (await dialog).accept();
    await expect.poll(() => page.locator("body").getAttribute("data-answer")).toBe("true");
  });

  it("rejects ambiguous CSS controls without clicking any row", async () => {
    await page.setContent(repeatedRows);
    await expect(
      ServerBrowserPage.click(page, {
        selector: 'button[data-testid="delete-row"]',
        timeoutMs: 1_000,
      }),
    ).rejects.toThrow(/strict mode violation/);
    expect(await page.locator("li").count()).toBe(5);
  });

  it("tells a click target that matches nothing from one that never becomes clickable", async () => {
    await page.setContent(`<button hidden>hidden</button>`);
    const failure = (selector: string) =>
      ServerBrowserPage.click(page, { selector, timeoutMs: 500 }).then(
        () => expect.unreachable(),
        ServerBrowserPage.toOperationError,
      );

    const absent = await failure(".definitely-no-such-t3-target");
    expect(absent.tag).toBe("PreviewAutomationTimeoutError");
    expect(absent.message).toBe(
      'The click may have happened and removed its target or navigated; check the page before retrying. No element matches ".definitely-no-such-t3-target" after the timeout; take a fresh snapshot and use its locator.',
    );
    expect(absent.cause).toMatchObject({ name: "TimeoutError" });
    const hidden = await failure("button");
    expect(hidden.tag).toBe("PreviewAutomationTimeoutError");
    expect(hidden.message).toBe(
      'The click may have happened; check the page before retrying. "button" still matches an element after the timeout. Playwright last saw: element is not visible.',
    );
  });

  it("gives a late target only the click's remaining time, not a fresh timeout", async () => {
    await page.setContent(`<script>
      setTimeout(() => document.body.insertAdjacentHTML("beforeend",
        '<button id="save" disabled onclick="document.body.dataset.clicked = 1">Save</button>'), 1000);
      setTimeout(() => document.querySelector("#save").disabled = false, 2500);
    </script>`);
    await expect(
      ServerBrowserPage.click(page, { selector: "#save", timeoutMs: 2_000 }),
    ).rejects.toThrow();
    expect(await page.locator("body").getAttribute("data-clicked")).toBeNull();
  });

  it("does not retarget a removed ref to a replacement node", async () => {
    await page.setContent("<button onclick=\"this.textContent='clicked'\">original</button>");
    const locator = buttonLocator((await takeSnapshot()).accessibilityTree, "original");
    await page.setContent("<button onclick=\"this.textContent='clicked'\">replacement</button>");
    await expect(ServerBrowserPage.click(page, { locator, timeoutMs: 100 })).rejects.toThrow();
    expect(await page.locator("button").textContent()).toBe("replacement");
  });

  it("targets iframe input refs and preserves the parent form", async () => {
    await page.setContent(
      '<input aria-label="parent"><iframe srcdoc="<input aria-label=child>"></iframe>',
    );
    await page.frameLocator("iframe").getByRole("textbox").waitFor();
    const result = await takeSnapshot();
    const line = String(result.accessibilityTree)
      .split("\n")
      .find((line) => line.includes('textbox "child"'));
    const locator = locators(line)[0]!;
    await ServerBrowserPage.type(page, { locator, text: "inside iframe", clear: true });
    expect(await page.frameLocator("iframe").getByRole("textbox").inputValue()).toBe(
      "inside iframe",
    );
    expect(await page.getByRole("textbox", { name: "parent" }).inputValue()).toBe("");
  });

  it("fills date and time fields from the dates agents type, and refuses a date it would have to guess", async () => {
    await page.setContent(`
      <label>Arrival <input id="date" type="date"></label>
      <label>Start <input id="time" type="time"></label>
      <p id="events"></p>
      <script>
        for (const kind of ["input", "change"])
          date.addEventListener(kind, () => (events.textContent += kind + ":" + date.value + " "));
      </script>`);
    const tree = String((await takeSnapshot()).accessibilityTree);
    const arrival = locators(tree.split("\n").find((line) => line.includes('"Arrival"')))[0]!;

    await ServerBrowserPage.type(page, { locator: arrival, text: "12/15/2026" });
    expect(await page.locator("#date").inputValue()).toBe("2026-12-15");
    expect(await page.locator("#events").textContent()).toBe("input:2026-12-15 change:2026-12-15 ");

    await ServerBrowserPage.type(page, { locator: arrival, text: "January 3, 2027", clear: true });
    expect(await page.locator("#date").inputValue()).toBe("2027-01-03");

    // 03/04 is March 4 or April 3 depending on the reader.
    await expect(
      ServerBrowserPage.type(page, { locator: arrival, text: "03/04/2027" }),
    ).rejects.toMatchObject({
      tag: "PreviewAutomationTargetNotEditableError",
      message: expect.stringContaining("YYYY-MM-DD"),
    });
    expect(await page.locator("#date").inputValue()).toBe("2027-01-03");

    await page.locator("#time").focus();
    await ServerBrowserPage.type(page, { text: "2:30 PM" });
    expect(await page.locator("#time").inputValue()).toBe("14:30");
  });

  it("types after a click by coordinates into a shadow-root field, and refuses a field inside an editable frame", async () => {
    await page.setContent(
      `<div id="host"></div><div contenteditable="true"><iframe srcdoc="<input id=inner>"></iframe></div><script>document.getElementById("host").attachShadow({mode:"open"}).innerHTML = "<input id=field>";</script>`,
    );
    const field = page.locator("#host #field");
    const box = (await field.boundingBox())!;
    await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
    await ServerBrowserPage.type(page, { text: "shadow" });
    expect(await field.inputValue()).toBe("shadow");

    // Refused for now: focus inside a frame cannot be checked from the top document.
    const inner = page.frameLocator("iframe").locator("#inner");
    await inner.click();
    await expect(ServerBrowserPage.type(page, { text: "frame" })).rejects.toMatchObject({
      tag: "PreviewAutomationTargetNotEditableError",
    });
    expect(await inner.inputValue()).toBe("");
  });

  it("shows dotted fields as dots wherever their value appears, keeping text values and refs", async () => {
    await page.setContent(`
      <table><tr><td>password:</td><td><input id="pw" type="password" aria-label="Password"></td></tr></table>
      <input aria-label="Username" value="maria">
      <input type="password" aria-label='saved" [ref=e2]: x' placeholder="hint" value="saved-pass">
      <input type="password" role="combobox" aria-label="Code" value="role-pass">
      <input aria-label="PIN" style="-webkit-text-security: disc" value="styled-pass">
      <div contenteditable style="-webkit-text-security: disc">editable-pass</div>
      <iframe srcdoc="<input type=password aria-label=child value=frame-pass>"></iframe>
      <iframe id="blank" src="javascript:false"></iframe>
      <p>Order styled-pass-2</p>
      <script>
        // A frame that never commits a document, filled by its parent.
        blank.contentDocument.body.innerHTML = "<input type=password aria-label=blank value=blank-pass>";
        // Page script can't change the value the snapshot sees.
        Object.defineProperty(HTMLInputElement.prototype, "value", { get: () => "" });
      </script>`);
    await page.frameLocator("iframe[srcdoc]").getByRole("textbox").waitFor();
    await ServerBrowserPage.type(page, { locator: "#pw", text: "typed-pass" });
    const result = await takeSnapshot();
    const tree = String(result.accessibilityTree);
    expect(tree).toContain('textbox "blank"');
    expect(tree).not.toMatch(
      /typed-pass|saved-pass|role-pass|styled-pass|editable-pass|frame-pass|blank-pass/,
    );
    expect(result.visibleText).not.toContain("editable-pass");
    expect(result.visibleText).toContain("Order ••••••••-2");
    expect(tree).toMatch(/textbox "Username" [^\n]*: maria$/m);
    const line = tree.split("\n").find((line) => line.includes('textbox "Password"'));
    expect(line).toMatch(/: •+$/);
    await ServerBrowserPage.type(page, { locator: locators(line)[0]!, text: "next", clear: true });
    expect(await page.locator("#pw").inputValue()).toBe("next");
  });

  it("masks dotted values in page text next to punctuation, with odd spaces, and at the cut", async () => {
    await page.setContent(`
      <input type="password" aria-label="PIN" value="123">
      <input type="password" aria-label="Phrase" value="open&nbsp;sesame">
      <p>PIN: 123. Code (123) id 1234</p>
      <p>open&nbsp;sesame</p>`);
    const text = (await takeSnapshot()).visibleText;
    expect(text).toContain("PIN: ••••••••. Code (••••••••) id 1234");
    expect(text).not.toMatch(/open|sesame/);
    await page.setContent(`
      <p>${"x".repeat(19_995)}long-secret</p>
      <input type="password" aria-label="Long" value="long-secret">`);
    const cut = (await takeSnapshot()).visibleText;
    expect(cut.length).toBe(20_000);
    expect(cut.slice(-8)).toBe("xxx•••••");
  });

  it("shows a data: link or blocked data: navigation by media type only", async () => {
    // Chromium keeps raw spaces and quotes in both, so a payload can't be cut at either.
    await page.setContent(`
      <a download href="data:text/plain;charset=&quot;a,b&quot;,head PAYLOAD'tail">Key</a>
      <a href="https://example.com/data:report,2026">Report</a>
      <a href="#">data:text/plain,label</a>
      <a href='"data:text/plain,relative'>Relative</a>
      <a href=" data:text/plain,PAYLOAD">Spaced</a>
      <a href="da&#9;ta:text/plain,PAYLOAD">Tabbed</a>
      <a href="data:text/plain,head&#x2028;PAYLOAD">Separated</a>
      <a href="data:PAYLOAD,x">Typeless</a>
      <a href="&#11;data:text/plain,PAYLOAD">Vertical tab</a>
      <a href="&#8;data:text/plain,PAYLOAD">Backspace</a>
      <a id="controlled">Controlled</a>
      <a id="escaped">Escaped</a>
      <script>
        controlled.href = "\\x01data:text/plain,PAYLOAD";
        escaped.href = "\\x02da\\tta:text/plain,PAYLOAD";
      </script>`);
    const tree = String((await takeSnapshot()).accessibilityTree);
    expect(tree.match(/\/url: data:text\/plain,…$/gm)).toHaveLength(8);
    expect(tree).toContain("/url: data:,…");
    expect(tree).toContain("/url: https://example.com/data:report,2026");
    expect(tree).toMatch(/link "data:text\/plain,label" \[ref=t3-/);
    expect(tree).not.toMatch(/PAYLOAD|tail|charset|\u2028/);
    expect(tree).toContain('/url: "\\"data:text/plain,relative"');
  });

  it("redacts a data: link whose scheme a password value would mask", async () => {
    await page.setContent(`
      <input type="password" aria-label="Scheme" value="data">
      <a download href="data:text/plain,PAYLOAD">Key</a>`);
    const tree = String((await takeSnapshot()).accessibilityTree);
    expect(tree).toContain("/url: ••••••••:text/plain,…");
    expect(tree).not.toContain("PAYLOAD");
  });

  it("shows a data: page's own URL by media type only", async () => {
    await page.goto("data:text/html,<title>Key</title>PAYLOAD");
    expect((await takeSnapshot()).url).toBe("data:text/html,…");
  });

  it("rejects refs from another tab", async () => {
    await page.setContent("<button>same label</button>");
    const locator = buttonLocator((await takeSnapshot()).accessibilityTree, "same label");
    const other = await context.newPage();
    await other.setContent("<button>same label</button>");
    await expect(ServerBrowserPage.click(other, { locator })).rejects.toThrow(/another tab/);
  });

  it("revokes refs after navigation even when labels are identical", async () => {
    await page.goto("data:text/html,<button>continue</button>");
    const locator = buttonLocator((await takeSnapshot()).accessibilityTree, "continue");
    await page.goto("data:text/html,<button>continue</button><p>new document</p>");
    await expect(ServerBrowserPage.click(page, { locator })).rejects.toThrow(/stale/);
  });

  it.each(["aria-ref=e1", " aria-ref=e1", "css=body >> aria-ref=e1"])(
    "does not allow native refs to bypass generation validation (%s)",
    async (locator) => {
      await page.setContent("<button>continue</button>");
      await takeSnapshot();
      await expect(ServerBrowserPage.click(page, { locator })).rejects.toThrow(/stale/);
    },
  );

  it("preserves quoted attribute values containing ref engine text", async () => {
    await page.setContent(
      '<button data-example=" >> aria-ref=e1" onclick="this.textContent=\'saved\'">save</button>',
    );
    await ServerBrowserPage.click(page, { selector: 'button[data-example=" >> aria-ref=e1"]' });
    expect(await page.locator("button").textContent()).toBe("saved");
  });

  it("evaluates top-level await and returns the last expression's value", async () => {
    await page.setContent("<title>Ready</title>");
    const result = await ServerBrowserPage.evaluate(
      cdp,
      { expression: "await Promise.resolve(); document.title" },
      5_000,
    );
    expect(result).toBe("Ready");
  });

  it("returns object contents even when a legacy caller asks for a remote reference", async () => {
    const input = decodeEvaluateInput({
      expression: "({ answer: 42, nested: { ready: true } })",
      returnByValue: false,
    });
    const result = await ServerBrowserPage.evaluate(cdp, input, 5_000);
    expect(result).toEqual({ answer: 42, nested: { ready: true } });
  });

  it("still awaits the promise an async function returns", async () => {
    const result = await ServerBrowserPage.evaluate(
      cdp,
      { expression: "(async () => { await 0; return 1 })()" },
      5_000,
    );
    expect(result).toBe(1);
  });

  it("does not rerun an expression whose SyntaxError is thrown at runtime", async () => {
    const evaluation = ServerBrowserPage.evaluate(
      cdp,
      { expression: "window.runs = (window.runs ?? 0) + 1; new Function('await 0')" },
      5_000,
    );
    await expect(evaluation).rejects.toThrow("await is only valid");
    expect(await page.evaluate("window.runs")).toBe(1);
  });

  it("does not rerun an expression whose awaited browser call rejects with a SyntaxError", async () => {
    let posts = 0;
    await page.route("http://preview.test/**", (route) => {
      if (route.request().method() === "POST") posts++;
      return route.fulfill({ contentType: "text/html", body: "<title>Ready</title>" });
    });
    await page.goto("http://preview.test/");
    const evaluation = ServerBrowserPage.evaluate(
      cdp,
      {
        expression:
          "(async () => { const r = await fetch('/api', { method: 'POST' }); return r.json() })()",
      },
      5_000,
    );
    await expect(evaluation).rejects.toThrow("is not valid JSON");
    expect(posts).toBe(1);
  });

  it("returns the result of a top-level await expression that reloads the page", async () => {
    await page.route("http://preview.test/", (route) =>
      route.fulfill({ contentType: "text/html", body: "<title>Ready</title>" }),
    );
    await page.goto("http://preview.test/");
    const result = await ServerBrowserPage.evaluate(
      cdp,
      { expression: "await 0; location.reload(); ({ clicked: true })" },
      5_000,
    );
    expect(result).toEqual({ clicked: true });
  });
});

describe("server browser snapshot screenshot", () => {
  let browser: Browser;
  let context: BrowserContext;

  beforeAll(async () => {
    // ServerBrowserContexts launches with these, and the capture scale depends on them.
    browser = await chromium.launch({
      headless: true,
      args: ["--disable-gpu", "--force-device-scale-factor=2"],
    });
  });
  afterAll(async () => {
    await browser?.close();
  });
  beforeEach(async () => {
    context = await browser.newContext({
      viewport: { width: 1280, height: 800 },
      deviceScaleFactor: 2,
    });
  });
  afterEach(async () => {
    await context.close();
  });

  // Blue on the left half and red on the right, so a mirrored left half shows up on the right.
  const halves = (overlay: string) => `
    <style>
      body { margin: 0; background: white; }
      .half { position: absolute; top: 0; width: 640px; height: 800px; }
      .overlay { position: fixed; inset: 0; ${overlay} }
    </style>
    <div class="half" style="left: 0; background: #2563eb"></div>
    <div class="half" style="left: 640px; background: #ef4444"></div>
    <div class="overlay"></div>`;

  const screenshotOf = async (html: string) => {
    const page = await context.newPage();
    await page.setContent(html);
    const input = {
      page,
      cdp: await context.newCDPSession(page),
      includeImage: true,
      renderScale: 2,
      fullScreenshot: true,
      consoleEntries: [],
      networkEntries: [],
      actionTimeline: [],
    };
    const { screenshot, fullScreenshot } = await ServerBrowserPage.snapshot(input);
    if (!screenshot) throw new Error("The snapshot took no screenshot.");
    // The server has no DOM types, so the decoder runs as page source.
    const points = [
      [0.15, 0.75],
      [0.85, 0.25],
      [0.85, 0.75],
    ];
    const pixels = (await page.evaluate(`(async () => {
      const bytes = Uint8Array.from(atob(${JSON.stringify(screenshot.data)}), (char) => char.charCodeAt(0));
      const bitmap = await createImageBitmap(new Blob([bytes], { type: "image/png" }));
      const canvas = document.createElement("canvas");
      canvas.width = bitmap.width;
      canvas.height = bitmap.height;
      const context = canvas.getContext("2d");
      context.drawImage(bitmap, 0, 0);
      return ${JSON.stringify(points)}.map(([x, y]) =>
        Array.from(context.getImageData(x * bitmap.width, y * bitmap.height, 1, 1).data),
      );
    })()`)) as Array<[number, number, number, number]>;
    return { screenshot, fullScreenshot, pixels };
  };
  const colorOf = ([red, green, blue]: readonly [number, number, number, number]) =>
    blue - red > 100 ? "blue" : red - blue > 100 ? "red" : `rgb(${red}, ${green}, ${blue})`;

  it("captures a blurred backdrop-filter page as rendered, not mirrored", async () => {
    const { screenshot, pixels } = await screenshotOf(halves("backdrop-filter: blur(4px);"));

    expect({
      size: [screenshot.width, screenshot.height],
      colors: pixels.map(colorOf),
    }).toEqual({ size: [1280, 800], colors: ["blue", "red", "red"] });
  });

  it("captures a plain page at the shrunk size with its content in place", async () => {
    const { screenshot, fullScreenshot, pixels } = await screenshotOf(halves(""));

    expect({
      size: [screenshot.width, screenshot.height],
      fullSize: [fullScreenshot?.width, fullScreenshot?.height],
      colors: pixels.map(colorOf),
    }).toEqual({
      size: [1280, 800],
      fullSize: [2560, 1600],
      colors: ["blue", "red", "red"],
    });
  });

  it("records the destination of a finite entrance animation without waiting on infinite ones", async () => {
    const page = await context.newPage();
    await page.setContent(`
      <style>
        body { margin: 0; background: #2563eb; }
        @keyframes enter { from { opacity: 0; } to { opacity: 1; } }
        @keyframes pulse { from { opacity: 0.5; } to { opacity: 1; } }
        button { animation: pulse 2s infinite; }
        #paused { animation: enter 2s paused; }
        #overlay { display: none; position: fixed; inset: 0; background: #ef4444; }
        #overlay.open { display: block; animation: enter 200ms both; }
      </style>
      <button onclick="document.querySelector('#overlay').classList.add('open')">Open</button>
      <div id="paused"></div>
      <div id="overlay"></div>
    `);
    await page.getByRole("button", { name: "Open" }).click();
    const frame = await ServerBrowserPage.captureFinalRecordingFrame(
      await context.newCDPSession(page),
      80,
    );
    expect(frame).toBeDefined();
    const pixel = (await page.evaluate(`(async () => {
      const bytes = Uint8Array.from(atob(${JSON.stringify(frame)}), char => char.charCodeAt(0));
      const bitmap = await createImageBitmap(new Blob([bytes], { type: "image/jpeg" }));
      const canvas = document.createElement("canvas");
      canvas.width = bitmap.width;
      canvas.height = bitmap.height;
      const context = canvas.getContext("2d");
      context.drawImage(bitmap, 0, 0);
      return Array.from(context.getImageData(bitmap.width / 2, bitmap.height / 2, 1, 1).data);
    })()`)) as [number, number, number, number];
    expect(colorOf(pixel)).toBe("red");
  });

  it("shrinks the screenshot of an XML document, whose createElement makes no canvas", async () => {
    const page = await context.newPage();
    await page.goto("data:text/xml,<a/>");
    const { screenshot } = await ServerBrowserPage.snapshot({
      page,
      cdp: await context.newCDPSession(page),
      includeImage: true,
      renderScale: 2,
      consoleEntries: [],
      networkEntries: [],
      actionTimeline: [],
    });

    expect([screenshot?.width, screenshot?.height]).toEqual([1280, 800]);
  });
});

describe("server browser drag", () => {
  it("fails the drag, not the server, when it times out while the cursor is still moving", async () => {
    const timedOut = new Error("locator.dragTo: Timeout 30000ms exceeded.");
    const box = { x: 0, y: 0, width: 20, height: 20 };
    const targetBox = Promise.withResolvers<typeof box>();
    const page = {
      locator: (selector: string) =>
        selector === "#card"
          ? {
              scrollIntoViewIfNeeded: async () => {},
              boundingBox: async () => box,
              dragTo: () => Promise.reject(timedOut),
            }
          : { boundingBox: () => targetBox.promise },
    } as unknown as Page;
    const unobserved: Array<unknown> = [];
    const onUnhandled = (reason: unknown) => unobserved.push(reason);
    process.on("unhandledRejection", onUnhandled);
    try {
      let finished = false;
      const settled = ServerBrowserPage.drag(page, { source: "#card", target: "#lane" }).then(
        () => null,
        (error: unknown) => error,
      );
      void settled.then(() => (finished = true));
      // Two macrotask turns: Node reports a rejection nobody observed after the first.
      for (let turn = 0; turn < 2; turn++) {
        // oxlint-disable-next-line t3code/no-real-time-wait-in-tests -- Node emits unhandledRejection only between macrotasks; no promise can mark that point.
        await new Promise((resolve) => setImmediate(resolve));
      }
      expect(finished).toBe(false);
      targetBox.resolve(box);

      expect(await settled).toBe(timedOut);
      expect(unobserved).toEqual([]);
    } finally {
      process.off("unhandledRejection", onUnhandled);
    }
  });

  it("moves the mouse after dragstart, so pages that track a drag with mousemove see it", async () => {
    const browser = await chromium.launch({ headless: true });
    try {
      const page = await browser.newPage();
      await page.setContent(`
        <div style="display:flex;gap:40px">
          <div id="source" draggable="true" style="width:200px;height:120px">source</div>
          <div id="target" style="width:200px;height:120px">target</div>
        </div>
        <script>
          window.events = [];
          let dragging = false;
          source.addEventListener("dragstart", (event) => {
            event.preventDefault();
            dragging = true;
            events.push("dragstart");
          });
          addEventListener("mousemove", () => dragging && events.push("mousemove"));
          addEventListener("mouseup", () => events.push("mouseup"));
        </script>`);

      await ServerBrowserPage.drag(page, { source: "#source", target: "#target" });

      const events = (await page.evaluate("window.events")) as Array<string>;
      expect(events.slice(0, 2)).toEqual(["dragstart", "mousemove"]);
      expect(events.at(-1)).toBe("mouseup");
    } finally {
      await browser.close();
    }
  });
});

describe("server browser action timeout", () => {
  type StepOptions = { readonly timeout?: number };
  it.each([
    {
      action: "hover",
      act: (page: Page) => ServerBrowserPage.hover(page, { selector: "#a", timeoutMs: 9_000 }),
      last: ["#a.hover 1"],
    },
    {
      action: "drag",
      act: (page: Page) =>
        ServerBrowserPage.drag(page, { source: "#a", target: "#b", timeoutMs: 9_000 }),
      last: ["#a.dragTo 1", "#b.boundingBox 1"],
    },
  ])("gives the $action's steps one shared timeout", async ({ act, last }) => {
    let now = 0;
    using _now = vi.spyOn(Date, "now").mockImplementation(() => now);
    const steps: Array<string> = [];
    const box = { x: 0, y: 0, width: 20, height: 20 };
    const page = {
      locator: (selector: string) => {
        const record = (step: string, options: StepOptions) =>
          steps.push(`${selector}.${step} ${options.timeout}`);
        return {
          // Each step that finds the target takes 5 of the 9 seconds.
          scrollIntoViewIfNeeded: async (options: StepOptions) => {
            record("scrollIntoViewIfNeeded", options);
            now += 5_000;
          },
          boundingBox: async (options: StepOptions) => {
            record("boundingBox", options);
            now += 5_000;
            return box;
          },
          hover: async (options: StepOptions) => record("hover", options),
          dragTo: async (_target: unknown, options: StepOptions) => record("dragTo", options),
        };
      },
    } as unknown as Page;

    await act(page);

    expect(steps).toEqual(["#a.scrollIntoViewIfNeeded 9000", "#a.boundingBox 4000", ...last]);
  });
});

describe("server browser click", () => {
  it("clicks a target the page replaced while it was being scrolled into view", async () => {
    let scrolls = 0;
    const clicks: Array<unknown> = [];
    const page = {
      locator: () => ({
        // Playwright resolves the node once; a page re-rendering it detaches that node.
        scrollIntoViewIfNeeded: async () => {
          if (scrolls++ === 0) {
            throw new Error("locator.scrollIntoViewIfNeeded: Element is not attached to the DOM");
          }
        },
        boundingBox: async () => ({ x: 0, y: 0, width: 20, height: 20 }),
        click: async (options: unknown) => {
          clicks.push(options);
        },
        count: async () => 1,
      }),
      once: () => {},
      off: () => {},
    } as unknown as Page;

    await expect(ServerBrowserPage.click(page, { selector: "#save" })).resolves.toEqual({
      x: 10,
      y: 10,
    });
    expect(clicks).toHaveLength(1);
  });

  it("retries a replaced target only within the action's timeout", async () => {
    vi.useFakeTimers();
    try {
      const timeouts: Array<number | undefined> = [];
      const clicks: Array<unknown> = [];
      const detached = new Error(
        "locator.scrollIntoViewIfNeeded: Element is not attached to the DOM",
      );
      const page = {
        locator: () => ({
          scrollIntoViewIfNeeded: async (options?: { timeout?: number }) => {
            timeouts.push(options?.timeout);
            vi.advanceTimersByTime(60);
            throw detached;
          },
          click: async (options: unknown) => {
            clicks.push(options);
          },
        }),
      } as unknown as Page;

      await expect(
        ServerBrowserPage.click(page, { selector: "#save", timeoutMs: 100 }),
      ).rejects.toBe(detached);
      expect(timeouts).toEqual([100, 40]);
      expect(clicks).toHaveLength(0);
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("server browser evaluate", () => {
  it("does not retry a parse error that arrives after the timeout", async () => {
    vi.useFakeTimers();
    try {
      const classic = Promise.withResolvers<unknown>();
      const send = vi.fn((method: string) =>
        method === "Runtime.evaluate" ? classic.promise : Promise.resolve({}),
      );
      const cdp = { send } as unknown as CDPSession;
      const evaluation = ServerBrowserPage.evaluate(cdp, { expression: "await 0; 1" }, 10);
      const rejected = expect(evaluation).rejects.toMatchObject({
        tag: "PreviewAutomationTimeoutError",
      });
      await vi.advanceTimersByTimeAsync(10);
      await rejected;
      classic.resolve({
        result: { type: "object" },
        exceptionDetails: {
          text: "Uncaught",
          scriptId: "4",
          exception: { type: "object", className: "SyntaxError" },
        },
      });
      await classic.promise;
      expect(send.mock.calls.map(([method]) => method)).toEqual([
        "Runtime.evaluate",
        "Runtime.terminateExecution",
      ]);
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("server browser type", () => {
  // As on a desktop tab whose Playwright utility world never answers.
  const stalledPage = (focusAnswer: () => Promise<unknown>, typed: string[]) =>
    ({
      locator: () => ({ last: () => ({ count: () => new Promise<number>(() => {}) }) }),
      evaluate: focusAnswer,
      keyboard: { insertText: async (text: string) => void typed.push(text) },
    }) as unknown as Page;

  it("types into the focused field when Playwright's utility world never answers", async () => {
    vi.useFakeTimers();
    try {
      const typed: string[] = [];
      let outcome: unknown = "pending";
      const page = stalledPage(async () => true, typed);
      void ServerBrowserPage.type(page, { text: "hello", timeoutMs: 300 }).then(
        () => (outcome = "typed"),
        (error: unknown) => (outcome = error),
      );
      await vi.advanceTimersByTimeAsync(300);
      expect(outcome).toBe("typed");
      expect(typed).toEqual(["hello"]);
    } finally {
      vi.useRealTimers();
    }
  });

  it("stops at its timeout without typing when the page never answers", async () => {
    vi.useFakeTimers();
    try {
      const typed: string[] = [];
      let outcome: unknown = "pending";
      const page = stalledPage(() => new Promise(() => {}), typed);
      void ServerBrowserPage.type(page, { text: "hello", timeoutMs: 300 }).then(
        () => (outcome = "typed"),
        (error: unknown) => (outcome = error),
      );
      await vi.advanceTimersByTimeAsync(300);
      expect(outcome).toMatchObject({
        tag: "PreviewAutomationTimeoutError",
        detail: { timeoutMs: 300 },
      });
      expect(typed).toEqual([]);
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("server browser unresponsive script", () => {
  it("leaves a page that answers alone", async () => {
    const send = vi.fn(async (_method: string) => ({}));
    await ServerBrowserPage.stopUnresponsiveScript({ send } as unknown as CDPSession);
    expect(send.mock.calls.map(([method]) => method)).toEqual(["Runtime.evaluate"]);
  });
});

describe("server browser wait", () => {
  it("ends at its timeout when a check never answers", async () => {
    // As on a desktop tab whose Playwright utility world never answers.
    const page = {
      locator: () => ({ count: () => new Promise<number>(() => {}) }),
    } as unknown as Page;
    vi.useFakeTimers();
    try {
      let failure: unknown;
      void ServerBrowserPage.waitFor(page, { selector: "button", timeoutMs: 300 }).catch(
        (error: unknown) => (failure = error),
      );
      await vi.advanceTimersByTimeAsync(300);
      expect(failure).toMatchObject({ tag: "PreviewAutomationTimeoutError" });
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("server browser net errors", () => {
  it.each([
    ["net::ERR_CONNECTION_REFUSED", "ERR_CONNECTION_REFUSED", -102],
    [
      "page.goto: net::ERR_HTTP2_PROTOCOL_ERROR at https://localhost:5173/",
      "ERR_HTTP2_PROTOCOL_ERROR",
      -2,
    ],
    ["net::ERR_TLS13_DOWNGRADE_DETECTED", "ERR_TLS13_DOWNGRADE_DETECTED", -2],
  ])("reads the whole error name from %j", (errorText, description, code) => {
    expect(ServerBrowserPage.parseNetError(errorText)).toEqual({ description, code });
  });
});
