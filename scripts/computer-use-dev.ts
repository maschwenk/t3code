// @effect-diagnostics nodeBuiltinImport:off - Host-side dev tool; hashes the home path to name its token file and serves the bake-off page.
// Drives the running dev app's computer-use tools from a shell, for agents
// whose own process lacks the macOS Accessibility and Screen Recording grants.
// See docs/operations/development.md#computer-use.
import * as NodeRuntime from "@effect/platform-node/NodeRuntime";
import * as NodeServices from "@effect/platform-node/NodeServices";
import * as NodeCrypto from "node:crypto";
import * as NodeHttp from "node:http";
import * as NodeOS from "node:os";
import * as Console from "effect/Console";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Path from "effect/Path";
import * as Schema from "effect/Schema";
import * as Stream from "effect/Stream";
import { Argument, Command, Flag } from "effect/cli";
import { FetchHttpClient, HttpClient, HttpClientRequest, HttpClientResponse } from "effect/http";
import { ChildProcess, ChildProcessSpawner } from "effect/process";

class DevHarnessError extends Schema.TaggedError<DevHarnessError>()("DevHarnessError", {
  message: Schema.String,
}) {}

const fail = (message: string) => Effect.fail(new DevHarnessError({ message }));

const decodeJson = Schema.decodeUnknownEffect(Schema.fromJsonString(Schema.Unknown));
const RuntimeState = Schema.Struct({
  origin: Schema.String,
  devUrl: Schema.optional(Schema.String),
});
const HarnessState = Schema.Struct({
  token: Schema.String,
  snapshotId: Schema.optional(Schema.String),
});
type HarnessState = typeof HarnessState.Type;
const ToolResult = Schema.Struct({
  content: Schema.Array(
    Schema.Union([
      Schema.Struct({ type: Schema.Literal("text"), text: Schema.String }),
      Schema.Struct({
        type: Schema.Literal("image"),
        data: Schema.String,
        mimeType: Schema.String,
      }),
    ]),
  ),
  isError: Schema.optional(Schema.Boolean),
});
type ToolResult = typeof ToolResult.Type;
const RpcResponse = Schema.Struct({
  result: Schema.optional(Schema.Unknown),
  error: Schema.optional(Schema.Struct({ message: Schema.String })),
});

export interface SnapshotElement {
  readonly ref: number;
  readonly role: string;
  readonly name: string | undefined;
  readonly value: string | undefined;
  /** Screen points. */
  readonly bounds: { x: number; y: number; width: number; height: number } | undefined;
}

const unquote = (quoted: string | undefined) =>
  quoted === undefined ? undefined : (JSON.parse(quoted) as string);

/** Elements of a snapshot's text, one per `[ref] role "name" = "value" ... @x,y wxh` line. */
export const parseElements = (text: string): SnapshotElement[] =>
  text.split("\n").flatMap((line) => {
    const match = /^\s*\[(\d+)\] (\S+)(?: ("(?:[^"\\]|\\.)*"))?(?: = ("(?:[^"\\]|\\.)*"))?/.exec(
      line,
    );
    if (!match) return [];
    const bounds = / @(-?\d+),(-?\d+) (\d+)x(\d+)(?: in |$)/.exec(line);
    return [
      {
        ref: Number(match[1]),
        role: match[2]!,
        name: unquote(match[3]),
        value: unquote(match[4]),
        bounds: bounds
          ? {
              x: Number(bounds[1]),
              y: Number(bounds[2]),
              width: Number(bounds[3]),
              height: Number(bounds[4]),
            }
          : undefined,
      },
    ];
  });

/** The first button named any of `names`, ignoring case; names differ across macOS versions. */
export const findButton = (elements: readonly SnapshotElement[], names: readonly string[]) =>
  elements.find(
    (element) =>
      element.role === "button" &&
      names.some((name) => name.toLowerCase() === element.name?.toLowerCase()),
  );

export const snapshotIdOf = (text: string) => /snapshotId=([\w-]+)/.exec(text)?.[1];

/** The checkout whose dev app holds the grants: the main worktree, even from a linked one. */
const defaultHome = Effect.gen(function* () {
  const path = yield* Path.Path;
  const commonDir = yield* run("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"]);
  return path.join(path.dirname(commonDir), ".t3");
});

const run = Effect.fn("computerUseDev.run")(function* (program: string, args: string[]) {
  const spawner = yield* ChildProcessSpawner.ChildProcessSpawner;
  const child = yield* spawner.spawn(
    ChildProcess.make(program, args, { stdin: "ignore", stdout: "pipe", stderr: "pipe" }),
  );
  const collect = (stream: typeof child.stdout) =>
    stream.pipe(Stream.decodeText(), Stream.mkString);
  const [stdout, stderr, code] = yield* Effect.all(
    [collect(child.stdout), collect(child.stderr), child.exitCode],
    { concurrency: "unbounded" },
  );
  if (code !== 0) return yield* fail(`${program} ${args.slice(0, 3).join(" ")} failed: ${stderr}`);
  return stdout.trim();
}, Effect.scoped);

const makeHarness = Effect.fn("computerUseDev.makeHarness")(function* (
  homeFlag: Option.Option<string>,
) {
  const fs = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const httpClient = yield* HttpClient.HttpClient;
  const home = path.resolve(Option.isSome(homeFlag) ? homeFlag.value : yield* defaultHome);
  const runtimePath = path.join(home, "userdata", "server-runtime.json");
  const runtime = yield* fs.readFileString(runtimePath).pipe(
    Effect.flatMap(decodeJson),
    Effect.flatMap(Schema.decodeUnknownEffect(RuntimeState)),
    Effect.mapError(
      () => new DevHarnessError({ message: `No running dev server found in ${runtimePath}.` }),
    ),
  );
  if (runtime.devUrl === undefined)
    return yield* fail(`${runtime.origin} is not a dev server; the harness only works in dev.`);

  // The token stays outside the repo and the dev home, readable only by this user.
  const stateDir = path.join(NodeOS.tmpdir(), "t3-computer-use-dev");
  const statePath = path.join(
    stateDir,
    `${NodeCrypto.createHash("sha256").update(home).digest("hex").slice(0, 16)}.json`,
  );
  const readState = fs
    .readFileString(statePath)
    .pipe(
      Effect.flatMap(decodeJson),
      Effect.flatMap(Schema.decodeUnknownEffect(HarnessState)),
      Effect.option,
    );
  const writeState = (state: HarnessState) =>
    fs
      .makeDirectory(stateDir, { recursive: true, mode: 0o700 })
      .pipe(
        Effect.andThen(fs.writeFileString(statePath, JSON.stringify(state), { mode: 0o600 })),
        Effect.andThen(fs.chmod(statePath, 0o600)),
      );
  const mint = Effect.gen(function* () {
    const bin = path.join(import.meta.dirname, "..", "apps", "server", "src", "bin.ts");
    const output = yield* run(process.execPath, [
      bin,
      "auth",
      "session",
      "issue",
      "--base-dir",
      home,
      "--token-only",
      "--ttl",
      "1d",
      "--label",
      "Dev harness",
      "--subject",
      "dev-harness",
    ]);
    const token = output.split("\n").at(-1)?.trim() ?? "";
    if (token.length === 0) return yield* fail("Could not issue a dev harness session.");
    yield* writeState({ token });
    return token;
  });

  const post = (token: string, body: unknown, sessionId?: string) =>
    HttpClientRequest.post(new URL("/mcp", runtime.origin)).pipe(
      HttpClientRequest.setHeaders({
        authorization: `Bearer ${token}`,
        accept: "application/json, text/event-stream",
        ...(sessionId ? { "mcp-session-id": sessionId, "mcp-protocol-version": "2025-06-18" } : {}),
      }),
      HttpClientRequest.bodyJson(body),
      Effect.flatMap(httpClient.execute),
      Effect.mapError(() => new DevHarnessError({ message: `Could not reach ${runtime.origin}.` })),
    );

  const readRpc = Effect.fn("ComputerUseDev.readRpc")(function* (
    response: HttpClientResponse.HttpClientResponse,
  ) {
    const text = yield* response.text.pipe(
      Effect.mapError(() => new DevHarnessError({ message: "Could not read the MCP response." })),
    );
    if (response.status < 200 || response.status >= 300)
      return yield* fail(`MCP request failed (${response.status}): ${text}`);
    // Streamable HTTP may answer as a one-event SSE stream.
    const payload = text.startsWith("{")
      ? text
      : text
          .split("\n")
          .filter((line) => line.startsWith("data:"))
          .map((line) => line.slice("data:".length))
          .join("");
    const decoded = yield* decodeJson(payload).pipe(
      Effect.flatMap(Schema.decodeUnknownEffect(RpcResponse)),
      Effect.mapError(() => new DevHarnessError({ message: `Unexpected MCP response: ${text}` })),
    );
    if (decoded.error) return yield* fail(decoded.error.message);
    return decoded.result;
  });

  const initialize = (token: string) =>
    post(token, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2025-06-18",
        capabilities: {},
        clientInfo: { name: "computer-use-dev", version: "1" },
      },
    });

  /** Calls one computer tool in a fresh MCP session, minting a session token when needed. */
  const call = Effect.fn("computerUseDev.call")(function* (name: string, args: unknown) {
    const saved = yield* readState;
    let token = Option.isSome(saved) ? saved.value.token : yield* mint;
    let initialized = yield* initialize(token);
    if (initialized.status === 401 && Option.isSome(saved)) {
      token = yield* mint;
      initialized = yield* initialize(token);
    }
    if (initialized.status === 401)
      return yield* fail(
        "The dev server refused the harness credential. Is the server running this branch?",
      );
    yield* readRpc(initialized);
    const sessionId = initialized.headers["mcp-session-id"];
    const result = yield* post(
      token,
      { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name, arguments: args } },
      sessionId,
    ).pipe(
      Effect.flatMap(readRpc),
      Effect.flatMap(Schema.decodeUnknownEffect(ToolResult)),
      Effect.mapError((error) =>
        error._tag === "DevHarnessError"
          ? error
          : new DevHarnessError({ message: `Unexpected ${name} result.` }),
      ),
    );
    const text = result.content.flatMap((part) => (part.type === "text" ? [part.text] : []));
    const snapshotId = text.map(snapshotIdOf).findLast((id) => id !== undefined);
    if (snapshotId) yield* writeState({ token, snapshotId });
    return result;
  });

  const latestSnapshotId = readState.pipe(
    Effect.map((state) => (Option.isSome(state) ? state.value.snapshotId : undefined)),
  );
  return { call, latestSnapshotId };
});

const textOf = (result: ToolResult) =>
  result.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("\n");

/** Prints the tool's text, saves its image when asked, and fails the command on a tool error. */
const report = Effect.fn("computerUseDev.report")(function* (
  result: ToolResult,
  image: Option.Option<string>,
) {
  yield* Console.log(textOf(result));
  const png = result.content.find((part) => part.type === "image");
  if (Option.isSome(image)) {
    if (!png || png.type !== "image") return yield* fail("The result carried no image.");
    const fs = yield* FileSystem.FileSystem;
    yield* fs.writeFile(image.value, Buffer.from(png.data, "base64"));
    yield* Console.log(`Saved image to ${image.value}`);
  }
  if (result.isError) return yield* fail("The tool reported an error.");
});

const home = Flag.String("home").pipe(
  Flag.withDescription("T3 home of the running dev app. Defaults to the main checkout's .t3."),
  Flag.optional,
);
const image = Flag.String("image").pipe(
  Flag.withDescription("Request a window image and write the PNG to this path."),
  Flag.optional,
);
const app = Argument.String("app");

const status = Command.make("status", { home }, ({ home }) =>
  makeHarness(home).pipe(
    Effect.flatMap((harness) => harness.call("computer_status", {})),
    Effect.flatMap((result) => report(result, Option.none())),
  ),
);

const open = Command.make(
  "open",
  { home, app, activate: Flag.Boolean("activate").pipe(Flag.withDefault(false)) },
  ({ home, app, activate }) =>
    makeHarness(home).pipe(
      Effect.flatMap((harness) => harness.call("computer_open", { app, activate })),
      Effect.flatMap((result) => report(result, Option.none())),
    ),
);

const snapshot = Command.make(
  "snapshot",
  {
    home,
    app,
    image,
    options: Argument.String("options").pipe(
      Argument.withDescription('Extra computer_snapshot input as JSON, such as {"query":"7"}.'),
      Argument.optional,
    ),
  },
  Effect.fn(function* ({ home, app, image, options }) {
    const harness = yield* makeHarness(home);
    const extra = Option.isSome(options) ? yield* decodeJson(options.value) : {};
    const result = yield* harness.call("computer_snapshot", {
      ...(extra as object),
      app,
      ...(Option.isSome(image) ? { includeImage: true } : {}),
    });
    yield* report(result, image);
  }),
);

const action = Command.make(
  "action",
  {
    home,
    image,
    input: Argument.String("input").pipe(
      Argument.withDescription(
        "computer_action input as JSON. snapshotId defaults to the latest snapshot this harness took.",
      ),
    ),
  },
  Effect.fn(function* ({ home, image, input }) {
    const harness = yield* makeHarness(home);
    const parsed = (yield* decodeJson(input)) as { readonly snapshotId?: string };
    const snapshotId = parsed.snapshotId ?? (yield* harness.latestSnapshotId);
    if (snapshotId === undefined) return yield* fail("Take a snapshot first, or pass snapshotId.");
    const result = yield* harness.call("computer_action", {
      ...parsed,
      snapshotId,
      ...(Option.isSome(image) ? { includeImage: true } : {}),
    });
    yield* report(result, image);
  }),
);

const CALCULATOR_BUTTONS = [
  ["All Clear", "Clear", "AC", "C"],
  ["7"],
  ["Add", "+", "Plus"],
  ["8"],
  ["Equals", "=", "Equal"],
] as const;

const smoke = Command.make(
  "smoke",
  { home },
  Effect.fn(function* ({ home }) {
    const harness = yield* makeHarness(home);
    const opened = yield* harness.call("computer_open", { app: "Calculator" });
    if (opened.isError) return yield* fail(`Could not open Calculator: ${textOf(opened)}`);
    const elements = parseElements(textOf(opened));
    const steps = [];
    for (const names of CALCULATOR_BUTTONS) {
      const button = findButton(elements, names);
      if (!button) return yield* fail(`No Calculator button named ${names.join(" or ")}.`);
      steps.push({ ref: button.ref, action: { kind: "press" } });
    }
    const acted = yield* harness.call("computer_action", {
      snapshotId: snapshotIdOf(textOf(opened)),
      steps,
    });
    if (acted.isError) return yield* fail(`Pressing 7 + 8 = failed: ${textOf(acted)}`);
    const after = yield* harness.call("computer_snapshot", { app: "Calculator" });
    if (after.isError || !textOf(after).includes('"15"'))
      return yield* fail(`Calculator does not show 15:\n${textOf(after)}`);
    yield* Console.log("Smoke passed: Calculator computed 7 + 8 = 15.");
  }),
);

interface PageEvent {
  readonly type: string;
  readonly isTrusted?: boolean;
  readonly cx?: number;
  readonly cy?: number;
  readonly key?: string;
  readonly value?: string;
  readonly inside?: boolean;
}

/** Serves the bake-off page on a free loopback port and keeps the events it logs. */
const servePage = Effect.acquireRelease(
  Effect.gen(function* () {
    const fs = yield* FileSystem.FileSystem;
    const path = yield* Path.Path;
    const html = yield* fs.readFileString(
      path.join(import.meta.dirname, "computer-use-bakeoff.html"),
    );
    const events: PageEvent[] = [];
    const server = NodeHttp.createServer((request, response) => {
      if (request.method !== "POST") {
        response.setHeader("content-type", "text/html");
        response.end(html);
        return;
      }
      let body = "";
      request.on("data", (chunk: Buffer) => (body += chunk.toString()));
      request.on("end", () => {
        events.push(JSON.parse(body) as PageEvent);
        response.end();
      });
    });
    const port = yield* Effect.callback<number>((resume) => {
      server.listen(0, "127.0.0.1", () => {
        const address = server.address();
        resume(Effect.succeed(typeof address === "object" && address ? address.port : 0));
      });
    });
    return { server, events, url: `http://127.0.0.1:${port}/` };
  }),
  ({ server }) =>
    Effect.sync(() => {
      server.closeAllConnections();
      server.close();
    }),
);

const waitFor = Effect.fn("computerUseDev.waitFor")(function* <E, R>(
  done: Effect.Effect<boolean, E, R>,
  message: string,
  timeoutMs = 15_000,
) {
  for (let waited = 0; waited < timeoutMs; waited += 200) {
    if (yield* done) return;
    yield* Effect.sleep(200);
  }
  return yield* fail(message);
});

const UserState = Schema.Struct({ mouse: Schema.String, front: Schema.String, chrome: Schema.Int });
/** Where the user's real pointer is, which app is in front, and how many Chromes run. */
const probeUser = run("osascript", [
  "-l",
  "JavaScript",
  "-e",
  `ObjC.import("AppKit");
const mouse = $.NSEvent.mouseLocation;
JSON.stringify({
  mouse: Math.round(mouse.x) + "," + Math.round(mouse.y),
  front: ObjC.unwrap($.NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier),
  chrome: Number($.NSRunningApplication.runningApplicationsWithBundleIdentifier("com.google.Chrome").count),
})`,
]).pipe(
  Effect.flatMap(Schema.decodeUnknownEffect(Schema.fromJsonString(UserState))),
  Effect.mapError(
    () => new DevHarnessError({ message: "Could not read the pointer and front app." }),
  ),
);

/**
 * Opens `url` in the bake-off's own background Chrome profile, quit by the pid
 * that profile names. The profile is kept so managed extensions open their
 * welcome tab only on its first run.
 */
const launchChrome = Effect.fn("computerUseDev.launchChrome")(function* (url: string) {
  const fs = yield* FileSystem.FileSystem;
  const profile = (yield* Path.Path).join(NodeOS.tmpdir(), "t3-computer-use-bakeoff-chrome");
  yield* fs.makeDirectory(profile, { recursive: true });
  const ours = (command: string) =>
    /\/Contents\/MacOS\/Google Chrome /.test(command) &&
    command.split(" ").includes(`--user-data-dir=${profile}`);
  yield* run("open", [
    "-g",
    "-na",
    "Google Chrome",
    "--args",
    `--user-data-dir=${profile}`,
    "--no-first-run",
    "--no-default-browser-check",
    // A covered Chrome stops painting without these two.
    "--disable-backgrounding-occluded-windows",
    "--disable-renderer-backgrounding",
    "--window-size=900,1000",
    "--window-position=40,40",
    url,
  ]);
  const find = run("ps", ["-axo", "pid=,command="]).pipe(
    Effect.map((lines) => lines.split("\n").find(ours)),
  );
  yield* waitFor(find.pipe(Effect.map((line) => line !== undefined)), "Chrome did not start.");
  const pid = Number.parseInt((yield* find) ?? "", 10);
  const running = run("ps", ["-o", "command=", "-p", String(pid)]).pipe(
    Effect.map(ours),
    Effect.orElseSucceed(() => false),
  );
  yield* Effect.addFinalizer(() =>
    Effect.gen(function* () {
      // Only while that pid's command line still names this profile.
      if (!(yield* running)) return;
      process.kill(pid, "SIGTERM");
      yield* waitFor(running.pipe(Effect.map((up) => !up)), "Chrome did not quit.");
    }).pipe(Effect.ignore),
  );
});

type Harness = Effect.Success<ReturnType<typeof makeHarness>>;
const CHROME = "Google Chrome";
const PAGE_TITLE = "Computer use bake-off";

interface Page {
  readonly text: string;
  readonly elements: readonly SnapshotElement[];
  readonly snapshotId: string | undefined;
  /** The element with this role whose name or value is `label`. */
  readonly find: (role: string, label: string) => SnapshotElement | undefined;
  /** The window image pixel at an offset in screen points from an element's top left. */
  readonly pixel: (
    element: SnapshotElement | undefined,
    dx: number,
    dy: number,
  ) => { x: number; y: number } | undefined;
}

const pageOf = (result: ToolResult): Page => {
  const text = textOf(result);
  const elements = parseElements(text);
  const window = elements.find((element) => element.role === "window")?.bounds;
  const png = result.content.find((part) => part.type === "image");
  // A PNG's IHDR chunk holds its width at bytes 16-19.
  const width =
    png?.type === "image" ? Buffer.from(png.data.slice(0, 32), "base64").readUInt32BE(16) : 0;
  const scale = window && width ? width / window.width : undefined;
  return {
    text,
    elements,
    snapshotId: snapshotIdOf(text),
    find: (role, label) =>
      elements.find(
        (element) => element.role === role && (element.name === label || element.value === label),
      ),
    pixel: (element, dx, dy) =>
      element?.bounds && window && scale
        ? {
            x: Math.round((element.bounds.x + dx - window.x) * scale),
            y: Math.round((element.bounds.y + dy - window.y) * scale),
          }
        : undefined,
  };
};

/**
 * The page with a window image. Closes any other tab first, such as the
 * welcome tab a managed extension opens some seconds after launch.
 */
const snapshotPage = Effect.fn("computerUseDev.snapshotPage")(function* (harness: Harness) {
  for (let attempt = 0; attempt < 10; attempt++) {
    const page = pageOf(
      yield* harness.call("computer_snapshot", { app: CHROME, includeImage: true }),
    );
    const steps = page.elements.flatMap((element, index) => {
      if (element.role !== "tab" || element.name?.startsWith(PAGE_TITLE)) return [];
      const close = page.elements
        .slice(index + 1)
        .find((next) => next.role === "button" && next.name === "Close");
      return close ? [{ ref: close.ref, action: { kind: "press" } }] : [];
    });
    if (steps.length === 0 && page.find("web_area", PAGE_TITLE)) return page;
    if (steps.length > 0)
      yield* harness.call("computer_action", { snapshotId: page.snapshotId, steps });
    yield* Effect.sleep(500);
  }
  return yield* fail("Chrome does not show the bake-off page.");
});

interface BakeoffTask {
  readonly name: string;
  /** computer_action steps, one call per entry against a fresh snapshot; undefined when a target is missing. */
  readonly actions: ReadonlyArray<(page: Page) => ReadonlyArray<object> | undefined>;
  /** Whether the page's DOM event log shows the task done. */
  readonly logged: (events: readonly PageEvent[]) => boolean;
  /** Whether the page shows the task's result at the end of the run. */
  readonly shows?: (page: Page) => boolean;
}

const trusted = (events: readonly PageEvent[], type: string) =>
  events.filter((event) => event.type === type && event.isTrusted);
const on = (element: SnapshotElement | undefined, action: object) =>
  element && [{ ref: element.ref, action }];
const at = (pixel: { x: number; y: number } | undefined, action: object) =>
  pixel && [{ action: { ...action, ...pixel } }];
const leftClick = { kind: "click", button: "left", count: 1 };

const BAKEOFF: readonly BakeoffTask[] = [
  {
    name: "button",
    actions: [(page) => on(page.find("button", "Increment"), leftClick)],
    logged: (events) => trusted(events, "btn.click").length === 1,
    shows: (page) => page.find("static_text", "count: 1") !== undefined,
  },
  {
    name: "canvas click at 101,60",
    actions: [
      (page) =>
        at(page.pixel(page.find("image", "drawing canvas"), 101, 60), {
          ...leftClick,
          kind: "click_at",
        }),
    ],
    logged: (events) =>
      trusted(events, "canvas.click")
        .map((event) => `${event.cx},${event.cy}`)
        .join() === "101,60",
    shows: (page) => page.find("static_text", "canvas click @ 101,60") !== undefined,
  },
  {
    name: "hover by ref",
    actions: [(page) => on(page.find("static_text", "Hover here to reveal:"), { kind: "move" })],
    logged: (events) => trusted(events, "hover.enter").length > 0,
  },
  {
    name: "move away by point",
    actions: [
      (page) => at(page.pixel(page.find("heading", PAGE_TITLE), 10, 10), { kind: "move_at" }),
    ],
    logged: (events) =>
      trusted(events, "mousemove").length > 0 && trusted(events, "mousedown").length === 0,
  },
  {
    name: "hover by point",
    actions: [
      (page) => {
        const label = page.find("static_text", "Hover here to reveal:");
        return at(page.pixel(label, (label?.bounds?.width ?? 0) + 200, 5), { kind: "move_at" });
      },
    ],
    logged: (events) => trusted(events, "hover.enter").length > 0,
  },
  {
    name: "revealed button",
    actions: [(page) => on(page.find("button", "Secret action"), leftClick)],
    logged: (events) => trusted(events, "secret.click").length === 1,
    shows: (page) => page.find("static_text", "secret clicked") !== undefined,
  },
  {
    name: "typing",
    actions: [
      (page) =>
        on(page.find("text_field", "Name"), { kind: "type", text: "Max Bakeoff", replace: false }),
    ],
    logged: (events) =>
      trusted(events, "keydown").length === 11 &&
      trusted(events, "input").some((event) => event.value === "Max Bakeoff"),
    shows: (page) => page.find("static_text", "typed: Max Bakeoff") !== undefined,
  },
  {
    name: "Return",
    actions: [(page) => on(page.find("text_field", "Name"), { kind: "key", key: "Return" })],
    logged: (events) =>
      trusted(events, "keydown")
        .map((event) => event.key)
        .join() === "Enter",
  },
  {
    name: "list scroll",
    actions: [(page) => on(page.find("static_text", "item 0"), { kind: "scroll", dx: 0, dy: 100 })],
    logged: (events) => trusted(events, "wheel").length > 0,
    shows: (page) => /"scrollTop [1-9]/.test(page.text),
  },
  {
    name: "drag",
    actions: [
      (page) => {
        const zone = page.find("static_text", "drop zone");
        return (
          zone && on(page.find("static_text", "drag"), { kind: "drag", to: { ref: zone.ref } })
        );
      },
    ],
    logged: (events) =>
      trusted(events, "drag.down").length === 1 &&
      trusted(events, "drag.up").some((event) => event.inside),
    shows: (page) => page.find("static_text", "DROPPED in zone") !== undefined,
  },
  {
    name: "select",
    actions: [
      (page) => on(page.find("combo_box", "Flavor"), { kind: "press" }),
      (page) => on(page.find("menu_item", "chocolate"), { kind: "press" }),
    ],
    logged: (events) => trusted(events, "select").some((event) => event.value === "chocolate"),
    shows: (page) => page.find("combo_box", "Flavor")?.value === "chocolate",
  },
];

/** Event types with their counts, plus the detail a task checks. */
const describeEvents = (events: readonly PageEvent[]) => {
  const counts = new Map<string, number>();
  for (const event of events) {
    const label = [
      event.type,
      event.cx === undefined ? "" : `${event.cx},${event.cy}`,
      event.type === "select" ? event.value : "",
      event.inside === undefined ? "" : event.inside ? "inside" : "outside",
      event.key !== undefined && event.key.length > 1 ? event.key : "",
      event.isTrusted ? "" : "(untrusted)",
    ]
      .filter(Boolean)
      .join(" ");
    counts.set(label, (counts.get(label) ?? 0) + 1);
  }
  return (
    [...counts].map(([label, count]) => (count > 1 ? `${label} ×${count}` : label)).join(", ") ||
    "none"
  );
};

const bakeoff = Command.make(
  "bakeoff",
  { home },
  Effect.fn(function* ({ home }) {
    const harness = yield* makeHarness(home);
    const user = yield* probeUser;
    if (user.chrome > 0)
      return yield* fail(
        "Quit Google Chrome first: computer tools find Chrome by app name, so the bake-off's must be the only one.",
      );
    const page = yield* servePage;
    yield* launchChrome(page.url);
    yield* waitFor(
      Effect.sync(() => page.events.some((event) => event.type === "ready")),
      "The bake-off page did not load.",
    );
    // A first launch can take the front despite -g.
    const restoreFront = Effect.gen(function* () {
      if ((yield* probeUser).front !== user.front) yield* run("open", ["-b", user.front]);
    });
    yield* restoreFront;
    yield* snapshotPage(harness);
    yield* restoreFront;
    const baseline = yield* probeUser;

    const untouched = (state: typeof UserState.Type) =>
      state.mouse === baseline.mouse && state.front === baseline.front;
    let snapshotSize = 0;
    const runs = [];
    for (const task of BAKEOFF) {
      const start = page.events.length;
      const responses: string[] = [];
      let error: string | undefined;
      let moved = false;
      for (const build of task.actions) {
        const view = yield* snapshotPage(harness);
        snapshotSize ||= view.text.length;
        const steps = build(view);
        if (!steps) {
          error = "target not in the snapshot";
          break;
        }
        const before = yield* probeUser;
        const acted = textOf(
          yield* harness.call("computer_action", { snapshotId: view.snapshotId, steps }),
        );
        const via = /^Completed 1 of 1 steps \((\w+)\)/.exec(acted)?.[1];
        responses.push(`${acted.length}${via ? ` ${via}` : ""}`);
        yield* Effect.sleep(300);
        moved ||= !untouched(before) || !untouched(yield* probeUser);
        if (!via) {
          error = acted.split("\n").slice(0, 2).join(" ");
          break;
        }
      }
      // Chrome handles posted input, and the page posts its log, asynchronously.
      yield* waitFor(
        Effect.sync(() => task.logged(page.events.slice(start))),
        "",
        3000,
      ).pipe(Effect.ignore);
      runs.push({ task, events: page.events.slice(start), responses, error, moved });
    }
    const final = pageOf(yield* harness.call("computer_snapshot", { app: CHROME }));
    const rows = runs.map(({ task, events, responses, error, moved }) => {
      const ok = !error && !moved && task.logged(events) && (task.shows?.(final) ?? true);
      const result = ok ? "pass" : `FAIL${error ? `: ${error}` : ""}`;
      return {
        ok,
        row: `| ${task.name} | ${describeEvents(events)} | ${responses.join(" + ")} | ${moved ? "moved" : "unchanged"} | ${result} |`,
      };
    });
    yield* Console.log(
      [
        "| task | page events | computer_action chars, via | pointer, front app | result |",
        "| --- | --- | --- | --- | --- |",
        ...rows.map(({ row }) => row),
        "",
        `${rows.filter(({ ok }) => ok).length}/${BAKEOFF.length} passed. First snapshot ${snapshotSize} chars. Pointer ${baseline.mouse}, front ${baseline.front}.`,
      ].join("\n"),
    );
  }, Effect.scoped),
);

const main = Command.make("computer-use-dev").pipe(
  Command.withDescription("Call the running dev app's computer-use tools as the Dev harness."),
  Command.withSubcommands([status, open, snapshot, action, smoke, bakeoff]),
);

if (import.meta.main) {
  Command.run(main, { version: "0.0.0" }).pipe(
    Effect.scoped,
    Effect.provide(Layer.mergeAll(NodeServices.layer, FetchHttpClient.layer)),
    NodeRuntime.runMain,
  );
}
