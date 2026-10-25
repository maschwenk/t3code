// @effect-diagnostics globalPerformance:off globalConsole:off -- Standalone benchmark, not a test timing assertion.
import * as HostProcess from "@t3tools/shared/HostProcess";
import * as Effect from "effect/Effect";
import { chromium } from "playwright-core";
import * as Page from "../src/preview/ServerBrowserPage.ts";

const runtime = Effect.runSync(
  Effect.all({ platform: HostProcess.Platform, arch: HostProcess.Architecture }),
);
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
  const cdp = await page.context().newCDPSession(page);
  const fixture = `<h1>Order review</h1><ul>${Array.from({ length: 40 }, (_, i) => `<li>order ${i + 1}<button onclick="document.body.dataset.clicked='${i + 1}'">Review order ${i + 1}</button></li>`).join("")}</ul><p id="status">Pending</p>`;
  const input = {
    page,
    cdp,
    includeImage: false,
    renderScale: 1,
    consoleEntries: [],
    networkEntries: [],
    actionTimeline: [],
  } as const;
  const samples: Array<{
    snapshotMs: number;
    fullMs: number;
    deltaMs: number;
    snapshotBytes: number;
    fullBytes: number;
    deltaBytes: number;
  }> = [];
  for (let trial = 0; trial < 7; trial++) {
    await page.setContent(fixture);
    Page.invalidateRefs(page);
    const snapshotAt = performance.now();
    const snapshot = await Page.snapshot(input);
    const snapshotMs = performance.now() - snapshotAt;
    const fullAt = performance.now();
    const full = await Page.observe(input, "benchmark");
    const fullMs = performance.now() - fullAt;
    if (full.mode !== "full") throw new Error("Expected full initial view");
    await page.locator("#status").evaluate((element) => {
      element.textContent = "Saved";
    });
    const deltaAt = performance.now();
    const delta = await Page.observe(input, "benchmark", full.revision);
    const deltaMs = performance.now() - deltaAt;
    if (delta.mode !== "delta") throw new Error("Expected delta after one changed line");
    const lines = full.tree.split("\n");
    lines.splice(delta.patch.startLine, delta.patch.deleteCount, ...delta.patch.lines);
    if (!lines.join("\n").includes("Saved")) throw new Error("Delta lost the changed state");
    const ref = /button "Review order 40" \[ref=([^\]]+)\]/.exec(lines.join("\n"))?.[1];
    if (!ref) throw new Error("Lost the final repeated control");
    await Page.click(page, { locator: `aria-ref=${delta.refPrefix}${ref}` });
    if ((await page.locator("body").getAttribute("data-clicked")) !== "40")
      throw new Error("Clicked the wrong repeated control");
    samples.push({
      snapshotMs,
      fullMs,
      deltaMs,
      snapshotBytes: Buffer.byteLength(JSON.stringify(snapshot)),
      fullBytes: Buffer.byteLength(JSON.stringify(full)),
      deltaBytes: Buffer.byteLength(JSON.stringify(delta)),
    });
  }
  const median = (key: keyof (typeof samples)[number]) =>
    samples.map((sample) => sample[key]).toSorted((a, b) => a - b)[3]!;
  console.log(
    JSON.stringify(
      {
        scope:
          "Headless Chromium page adapter; server payload bytes before MCP formatting, not model tokens or an agent task comparison",
        runtime: {
          node: process.version,
          ...runtime,
          browser: browser.version(),
        },
        trials: samples.length,
        viewport: { width: 1280, height: 720 },
        correctness:
          "Every delta reconstructs the saved state and its fresh ref targets repeated control 40",
        medianMs: {
          snapshot: median("snapshotMs"),
          full: median("fullMs"),
          delta: median("deltaMs"),
        },
        medianBytes: {
          snapshot: median("snapshotBytes"),
          full: median("fullBytes"),
          delta: median("deltaBytes"),
        },
        samples,
      },
      null,
      2,
    ),
  );
} finally {
  await browser.close();
}
