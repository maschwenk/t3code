import * as NodeTest from "node:test";
import * as NodeAssert from "node:assert/strict";
import * as NodeChildProcess from "node:child_process";
import * as NodeHttp from "node:http";
import * as NodeCrypto from "node:crypto";
import * as NodeFSP from "node:fs/promises";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";
import * as NodeOS from "node:os";
import * as NodeEvents from "node:events";
const supplied = process.env.T3_CHROMIUM_TEST_APP;
const extensionTest = process.env.T3_CHROMIUM_TEST_EXTENSION === "1";
const context = {
  environmentID: "fixture-environment",
  threadId: "fixture-thread",
  tabId: "fixture-tab",
  profileId: "fixture-profile",
  show: false,
};
const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
async function until(read, accept, timeout = 10000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    const value = await read();
    if (accept(value)) return value;
    await delay(25);
  }
  throw Error("Fixture milestone timed out");
}
class Helper {
  constructor(app, home, evidence, motion) {
    this.token = NodeCrypto.randomBytes(32).toString("hex");
    this.events = [];
    this.pending = new Map();
    this.next = 0;
    this.buffer = "";
    this.errors = "";
    const environment = {
      ...process.env,
      HOME: home,
      T3_CHROMIUM_STATE: NodePath.join(home, "Library/Application Support/T3Native/Chromium"),
      T3_CHROMIUM_TOKEN: this.token,
      T3_CHROMIUM_FIXTURE_EVIDENCE: evidence,
      T3_CHROMIUM_FIXTURE_MOTION: motion ?? "",
    };
    delete environment.ELECTRON_RUN_AS_NODE;
    delete environment.NODE_OPTIONS;
    this.child = NodeChildProcess.spawn(NodePath.join(app, "Contents/MacOS/Electron"), [], {
      env: environment,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.exited = NodeEvents.once(this.child, "exit");
    this.child.stderr.on("data", (data) => {
      this.errors += data;
    });
    this.child.stdout.on("data", (data) => {
      this.buffer += data;
      let end;
      while ((end = this.buffer.indexOf("\n")) >= 0) {
        const line = this.buffer.slice(0, end);
        this.buffer = this.buffer.slice(end + 1);
        if (!line.startsWith("T3CHROMIUM ")) continue;
        const message = JSON.parse(line.slice(11));
        NodeAssert.equal(message.token, this.token);
        delete message.token;
        if (message.event) this.events.push(message);
        const pending = this.pending.get(message.id);
        if (pending) {
          this.pending.delete(message.id);
          clearTimeout(pending.timer);
          if (message.error)
            pending.reject(
              Object.assign(Error(message.error.message), { tag: message.error._tag }),
            );
          else pending.resolve(message.result);
        }
      }
    });
    this.child.once("exit", (code, signal) => {
      this.exit = { code, signal };
      for (const pending of this.pending.values()) {
        clearTimeout(pending.timer);
        pending.reject(Error("Helper exited: " + code + " " + signal));
      }
      this.pending.clear();
    });
  }
  rpc(method, input = {}, timeout = 20000) {
    return new Promise((resolve, reject) => {
      const id = "r" + ++this.next;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(Error("Timed out: " + method));
      }, timeout);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(JSON.stringify({ token: this.token, id, method, input }) + "\n");
    });
  }
  action(operation, input = {}, timeout = 10000) {
    return this.rpc(
      "automation",
      { ...context, operation, input, timeoutMs: timeout },
      timeout + 3000,
    );
  }
  async ready() {
    await until(() => this.events.find((event) => event.event === "ready"), Boolean);
    NodeAssert.equal((await this.rpc("hello")).engine, "chromium");
  }
  async stop() {
    if (this.exit) return;
    await this.rpc("stopHelper");
    const [code] = await Promise.race([
      this.exited,
      delay(10000).then(() => {
        throw Error("Owned helper failed to quit");
      }),
    ]);
    NodeAssert.equal(code, 0);
  }
  async cleanup(log) {
    if (!this.exit) {
      this.child.stdin.end();
      await Promise.race([this.exited, delay(3000)]);
      if (!this.exit) {
        this.child.kill("SIGTERM");
        await this.exited;
      }
    }
    await NodeFSP.writeFile(log, this.errors);
  }
}
async function observedApp(root) {
  const app = NodePath.join(root, "T3 Browser.app");
  await NodeFSP.cp(supplied, app, {
    recursive: true,
    dereference: false,
    verbatimSymlinks: true,
  });
  const assets = NodePath.join(app, "Contents/Resources/app");
  // A copy retains the exact signed product main/preloads/frameworks. Its test
  // entry observes genuine Electron windows and hides UI; no extension API stub.
  NodeAssert.deepEqual(
    await NodeFSP.readFile(NodePath.join(assets, "main.mjs")),
    await NodeFSP.readFile(NodePath.join(supplied, "Contents/Resources/app/main.mjs")),
  );
  await NodeFSP.cp(
    NodePath.join(NodePath.dirname(NodeURL.fileURLToPath(import.meta.url)), "runtime-observer.mjs"),
    NodePath.join(assets, "runtime-observer.mjs"),
  );
  const metadata = JSON.parse(
    await NodeFSP.readFile(NodePath.join(assets, "package.json"), "utf8"),
  );
  metadata.main = "runtime-observer.mjs";
  await NodeFSP.writeFile(NodePath.join(assets, "package.json"), JSON.stringify(metadata));
  const entitlements = NodePath.join(root, "fixture-entitlements.plist");
  await NodeFSP.writeFile(
    entitlements,
    NodeChildProcess.execFileSync("/usr/bin/codesign", ["-d", "--entitlements", ":-", supplied], {
      stdio: "pipe",
    }),
  );
  NodeChildProcess.execFileSync(
    "/usr/bin/codesign",
    [
      "--force",
      "--sign",
      process.env.T3_CHROMIUM_TEST_SIGN_IDENTITY ?? "-",
      "--options",
      "runtime",
      "--entitlements",
      entitlements,
      app,
    ],
    { stdio: "pipe" },
  );
  NodeChildProcess.execFileSync("/usr/bin/codesign", ["--verify", "--deep", "--strict", app]);
  return app;
}
NodeTest.test(
  "signed isolated Chromium: actual pages, cancellation, navigation identity, cursor, downloads and persistence",
  { skip: !supplied, timeout: 180000 },
  async (t) => {
    // oxlint-disable-next-line t3code/no-global-process-runtime -- Standalone executable fixture uses the actual host architecture.
    NodeAssert.equal(NodeOS.arch(), "arm64");
    NodeChildProcess.execFileSync("/usr/bin/codesign", [
      "--verify",
      "--deep",
      "--strict",
      supplied,
    ]);
    await NodeFSP.mkdir("/tmp/t3-native-evidence", { recursive: true });
    const root = await NodeFSP.realpath(
      await NodeFSP.mkdtemp("/tmp/t3-native-evidence/chromium-runtime-"),
    );
    const home = NodePath.join(root, "home");
    await NodeFSP.mkdir(home);
    t.diagnostic("evidence: " + root);
    let streaming;
    const html =
      '<html><head><title>Actual Chromium fixture</title></head><body style="height:2200px"><form><input id="username" autocomplete="username"><input id="password" type="password" autocomplete="current-password"></form><div style="height:800px"></div><div style="margin-left:140px;width:220px;height:120px;overflow:hidden"><button id="target" style="margin-left:-40px;width:260px;height:60px" onclick="window.clicked=(window.clicked||0)+1;window.trusted=event.isTrusted">Click fixture</button></div><a id="download" href="/download">Download fixture</a><script>window.clicked=0</script></body></html>';
    const server = NodeHttp.createServer((request, response) => {
      if (request.url === "/download") {
        streaming = response;
        response.writeHead(200, {
          "Content-Type": "application/octet-stream",
          "Content-Disposition": 'attachment; filename="fixture.bin"',
          "Content-Length": "50000000",
        });
        response.write(Buffer.alloc(1024, 7));
        return;
      }
      response.writeHead(200, { "Content-Type": "text/html" });
      response.end(request.url === "/new" ? html.replace('id="target"', 'id="late"') : html);
    });
    server.listen(0, "127.0.0.1");
    await NodeEvents.once(server, "listening");
    const origin = "http://127.0.0.1:" + server.address().port;
    const app = await observedApp(root);
    let helper = new Helper(app, home, root, "no-preference");
    try {
      await helper.ready();
      await t.test("concurrent opens share one real native window", async () => {
        const results = await Promise.all(
          Array.from({ length: 8 }, () => helper.rpc("open", { ...context, url: origin })),
        );
        NodeAssert.equal(new Set(results.map((result) => result.windowId)).size, 1);
        NodeAssert.equal(results[0].visible, false);
        await helper.action("navigate", { url: origin });
        await until(
          () =>
            helper.action("evaluate", {
              expression: 'matchMedia("(prefers-reduced-motion: no-preference)").matches',
            }),
          Boolean,
        );
        t.diagnostic("finite animation fixture: actual Chromium media preference is no-preference");
      });
      await t.test(
        "real scrolled clipped zoomed target receives trusted input and cursor survives PNG capture",
        async () => {
          t.diagnostic(
            JSON.stringify(
              await helper.action("evaluate", {
                expression:
                  '({reducedMotion:matchMedia("(prefers-reduced-motion:reduce)").matches,deviceScale:devicePixelRatio,ready:document.readyState})',
              }),
            ),
          );
          await helper.rpc("zoom", { ...context, factor: 1.5 });
          await helper.action("click", { selector: "#target" });
          const actual = await helper.action("evaluate", {
            expression:
              '({clicked, trusted, point:(()=>{const r=document.querySelector("#target").getBoundingClientRect(),p=document.querySelector("#target").parentElement.getBoundingClientRect();return{x:(Math.max(0,r.left,p.left)+Math.min(innerWidth,r.right,p.right))/2,y:(Math.max(0,r.top,p.top)+Math.min(innerHeight,r.bottom,p.bottom))/2}})()})',
          });
          NodeAssert.equal(actual.clicked, 1);
          NodeAssert.equal(actual.trusted, true);
          const status = await helper.action("status");
          NodeAssert.equal(status.agentCursor.visible, true);
          NodeAssert.equal(status.agentCursor.inFlight, false);
          NodeAssert.ok(Math.abs(status.agentCursor.position.x - actual.point.x) < 1);
          NodeAssert.ok(Math.abs(status.agentCursor.position.y - actual.point.y) < 1);
          const capture = await helper.action("snapshot", {});
          NodeAssert.equal(capture.screenshot.mimeType, "image/png");
          await NodeFSP.writeFile(
            NodePath.join(root, "cursor.png"),
            Buffer.from(capture.screenshot.data, "base64"),
          );
          NodeAssert.equal((await helper.action("status")).agentCursor.visible, true);
          NodeAssert.ok(
            capture.actionTimeline.some(
              (action) => action.action === "click" && action.status === "succeeded",
            ),
          );
        },
      );
      await t.test(
        "Stop during an actual finite cursor move prevents input and hides stale overlay",
        async () => {
          const clickedBefore = await helper.action("evaluate", { expression: "clicked" });
          const pending = helper.action("click", { selector: "#target" }).then(
            () => null,
            (error) => error,
          );
          await until(
            () => helper.action("status"),
            (status) => status.agentCursor?.inFlight === true && status.agentCursor.animations > 0,
          );
          await helper.rpc("stop", context);
          const error = await pending;
          NodeAssert.equal(error?.tag, "PreviewAutomationControlInterruptedError");
          NodeAssert.equal(
            await helper.action("evaluate", { expression: "clicked" }),
            clickedBefore,
          );
          NodeAssert.equal((await helper.action("status")).agentCursor.visible, false);
        },
      );
      await t.test("pending selector action refuses the next document", async () => {
        const pending = helper.action("click", { selector: "#late" }).then(
          () => null,
          (error) => error,
        );
        await until(
          () => helper.action("status"),
          (status) => status.agentCursor?.visible === true,
        );
        await helper.action("navigate", { url: origin + "/new" });
        const error = await pending;
        NodeAssert.equal(error?.tag, "PreviewAutomationControlInterruptedError");
        NodeAssert.equal(await helper.action("evaluate", { expression: "clicked" }), 0);
      });
      await t.test(
        "actual type and persistent page session survive owned-process restart",
        async () => {
          await helper.action("type", { selector: "#username", text: "fixture-user", clear: true });
          NodeAssert.equal(
            await helper.action("evaluate", {
              expression: 'document.querySelector("#username").value',
            }),
            "fixture-user",
          );
          await helper.action("evaluate", {
            expression:
              'localStorage.fixture="restart-preserved";document.cookie="fixtureSession=private; Max-Age=3600; SameSite=Lax"',
          });
          await helper.stop();
          await helper.cleanup(NodePath.join(root, "first.stderr.log"));
          helper = new Helper(app, home, root, "no-preference");
          await helper.ready();
          await helper.rpc("open", { ...context, url: origin });
          await helper.action("navigate", { url: origin });
          NodeAssert.equal(
            await helper.action("evaluate", { expression: "localStorage.fixture" }),
            "restart-preserved",
          );
          NodeAssert.match(
            await helper.action("evaluate", { expression: "document.cookie" }),
            /fixtureSession=private/,
          );
        },
      );
      await t.test(
        "active real download cancellation removes partial bytes and quit stops the owned helper",
        async () => {
          await helper.action("click", { selector: "#download" }).catch((error) => {
            if (error.tag !== "PreviewAutomationControlInterruptedError") throw error;
          });
          await until(
            () => helper.rpc("downloads"),
            (downloads) => downloads.length === 1,
          );
          await helper.rpc("cancelDownloads");
          NodeAssert.deepEqual(await helper.rpc("downloads"), []);
          NodeAssert.deepEqual(
            await NodeFSP.readdir(
              NodePath.join(home, "Library/Application Support/T3Native/Chromium/downloads"),
            ),
            [],
          );
          await helper.action("click", { selector: "#download" }).catch((error) => {
            if (error.tag !== "PreviewAutomationControlInterruptedError") throw error;
          });
          await until(
            () => helper.rpc("downloads"),
            (downloads) => downloads.length === 1,
          );
          await helper.stop();
          NodeAssert.deepEqual(
            await NodeFSP.readdir(
              NodePath.join(home, "Library/Application Support/T3Native/Chromium/downloads"),
            ),
            [],
          );
        },
      );
      await NodeFSP.writeFile(
        NodePath.join(root, "result.json"),
        JSON.stringify(
          {
            app: supplied,
            protocol: true,
            cursor: true,
            stop: true,
            documentIdentity: true,
            concurrentOpen: true,
            restart: true,
            downloads: true,
            vaultAccess: false,
          },
          null,
          2,
        ),
      );
    } finally {
      streaming?.destroy();
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
      await helper.cleanup(NodePath.join(root, "final.stderr.log"));
    }
  },
);
NodeTest.test(
  "official 1Password opens genuine anonymous onboarding on the first action and after restart",
  { skip: !supplied || !extensionTest, timeout: 180000 },
  async (t) => {
    // Never use the real user's extension/profile/host manifests. System 1Password
    // manifests would allow a desktop-vault connection, so refuse this fixture.
    for (const directory of [
      "/Library/Google/Chrome/NativeMessagingHosts",
      "/Library/Application Support/Chromium/NativeMessagingHosts",
      "/Library/Microsoft/Edge/NativeMessagingHosts",
    ]) {
      const files = await NodeFSP.readdir(directory).catch(() => []);
      NodeAssert.ok(
        !files.some((name) => /1password|agilebits|2bua8c4s2c/i.test(name)),
        "Vault-capable system native host present; do not run anonymous fixture.",
      );
    }
    await NodeFSP.mkdir("/tmp/t3-native-evidence", { recursive: true });
    const root = await NodeFSP.realpath(
      await NodeFSP.mkdtemp("/tmp/t3-native-evidence/chromium-extension-"),
    );
    t.diagnostic("evidence: " + root);
    const app = await observedApp(root),
      home = NodePath.join(root, "home");
    await NodeFSP.mkdir(home);
    let helper = new Helper(app, home, NodePath.join(root, "first"));
    try {
      await helper.ready();
      await helper.rpc("open", { ...context, url: "about:blank" });
      const installed = await helper.rpc("install", {}, 90000);
      const password = installed.find(
        (extension) => extension.id === "aeblfdkhhhdcdjpifhhbdiojplfjncoa",
      );
      NodeAssert.ok(password?.enabled);
      NodeAssert.equal(password.loadError, null);
      await helper.rpc("popup", context);
      const report = await until(
        () =>
          NodeFSP.readFile(NodePath.join(root, "first/extension-ui.json"), "utf8")
            .then(JSON.parse)
            .catch(() => null),
        Boolean,
        20000,
      );
      NodeAssert.match(report.url, /^chrome-extension:\/\/aeblfdkhhhdcdjpifhhbdiojplfjncoa\//);
      NodeAssert.equal(report.title, "1Password");
      NodeAssert.equal(report.uiReady, true);
      NodeAssert.match(report.url, /app\/app.html/);
      NodeAssert.match(report.text, /Welcome to 1Password/);
      t.diagnostic(
        "anonymous onboarding readiness: " +
          Boolean(report.uiReady) +
          "; isolated native host unavailable: " +
          helper.errors.includes("Specified native messaging host not found"),
      );
      await helper.stop();
      await helper.cleanup(NodePath.join(root, "first.stderr.log"));
      helper = new Helper(app, home, NodePath.join(root, "restart"));
      await helper.ready();
      await helper.rpc("open", { ...context, url: "about:blank" });
      const restored = (await helper.rpc("extensions")).find(
        (extension) => extension.id === password.id,
      );
      NodeAssert.equal(restored?.version, password.version);
      NodeAssert.equal(restored?.loadError, null);
      await helper.rpc("popup", context);
      const reopened = await until(
        () =>
          NodeFSP.readFile(NodePath.join(root, "restart/extension-ui.json"), "utf8")
            .then(JSON.parse)
            .catch(() => null),
        Boolean,
        20000,
      );
      NodeAssert.equal(reopened.title, "1Password");
      NodeAssert.equal(reopened.uiReady, true);
      NodeAssert.match(reopened.url, /app\/app.html/);
      NodeAssert.match(reopened.text, /Welcome to 1Password/);
      await helper.stop();
      await NodeFSP.writeFile(
        NodePath.join(root, "result.json"),
        JSON.stringify(
          {
            officialExtension: password.id,
            version: password.version,
            onboardingDocument: true,
            onboardingReady: Boolean(report.uiReady && reopened.uiReady),
            restart: true,
            actualVaultAutofill:
              "unverified: requires user-controlled sign-in/unlock or Add Browser trust",
            vaultAccess: false,
          },
          null,
          2,
        ),
      );
    } finally {
      await helper.cleanup(NodePath.join(root, "final.stderr.log"));
    }
  },
);
