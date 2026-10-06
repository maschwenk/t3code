// Drives the running dev app's computer-use tools from a shell, for agents
// whose own process lacks the macOS Accessibility and Screen Recording grants.
// See docs/operations/development.md#computer-use.
import * as NodeRuntime from "@effect/platform-node/NodeRuntime";
import * as NodeServices from "@effect/platform-node/NodeServices";
import * as NodeCrypto from "node:crypto";
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
}

/** Elements of a snapshot's text, one per `[ref] role "name" ...` line. */
export const parseElements = (text: string): SnapshotElement[] =>
  text.split("\n").flatMap((line) => {
    const match = /^\s*\[(\d+)\] (\S+)(?: ("(?:[^"\\]|\\.)*"))?/.exec(line);
    if (!match) return [];
    const quoted = match[3];
    return [
      {
        ref: Number(match[1]),
        role: match[2]!,
        name: quoted === undefined ? undefined : (JSON.parse(quoted) as string),
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

  const readRpc = (response: HttpClientResponse.HttpClientResponse) =>
    Effect.gen(function* () {
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

const main = Command.make("computer-use-dev").pipe(
  Command.withDescription("Call the running dev app's computer-use tools as the Dev harness."),
  Command.withSubcommands([status, open, snapshot, action, smoke]),
);

if (import.meta.main) {
  Command.run(main, { version: "0.0.0" }).pipe(
    Effect.scoped,
    Effect.provide(Layer.mergeAll(NodeServices.layer, FetchHttpClient.layer)),
    NodeRuntime.runMain,
  );
}
