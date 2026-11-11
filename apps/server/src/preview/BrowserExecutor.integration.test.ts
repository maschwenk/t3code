import * as NodeCrypto from "@effect/platform-node/NodeCrypto";
import * as NodeServices from "@effect/platform-node/NodeServices";
import { expect, it } from "@effect/vitest";
import {
  EnvironmentId,
  PreviewTabId,
  ProviderInstanceId,
  ThreadId,
  PREVIEW_AUTOMATION_SERVER_OPERATIONS,
  PreviewAutomationClickInput,
  PreviewAutomationDialogInput,
  PreviewAutomationTypeInput,
  PreviewAutomationWaitForInput,
} from "@t3tools/contracts";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Result from "effect/Result";
import * as Schema from "effect/Schema";
import * as Stream from "effect/Stream";
import { chromium, type Dialog } from "playwright-core";
import * as Broker from "../mcp/PreviewAutomationBroker.ts";
import * as BrowserExecutor from "./BrowserExecutor.ts";
import * as BrowserGoal from "./BrowserGoal.ts";
import * as Page from "./ServerBrowserPage.ts";
import { SessionControl } from "./SessionControl.ts";

const scope = {
  environmentId: EnvironmentId.make("executor-browser-env"),
  requestNamespace: "executor-browser-session",
  thread: {
    threadId: ThreadId.make("executor-browser-thread"),
    providerSessionId: "session",
    providerInstanceId: ProviderInstanceId.make("codex"),
  },
  client: undefined,
  capabilities: new Set(["preview"] as const),
  issuedAt: 1,
};
const tabId = PreviewTabId.make("fixture-tab");
const executorLayer = (decider: Layer.Layer<BrowserGoal.GoalDecider>) =>
  BrowserExecutor.layer.pipe(
    Layer.provideMerge(Broker.layer),
    Layer.provide(decider),
    Layer.provide(Layer.mergeAll(NodeServices.layer, NodeCrypto.layer)),
  );
const layer = executorLayer(BrowserGoal.layerJev.pipe(Layer.provide(NodeServices.layer)));
const decodeClick = Schema.decodeUnknownSync(PreviewAutomationClickInput);
const decodeType = Schema.decodeUnknownSync(PreviewAutomationTypeInput);
const decodeDialog = Schema.decodeUnknownSync(PreviewAutomationDialogInput);
const decodeWait = Schema.decodeUnknownSync(PreviewAutomationWaitForInput);

/** Serves broker requests from a real headless page through T3's own page operations. */
const hostPage = Effect.fn("BrowserExecutorIntegrationTest.hostPage")(function* (
  html: string,
  takeOverAfter?: string,
) {
  const browser = yield* Effect.acquireRelease(
    Effect.promise(() => chromium.launch({ headless: true })),
    (value) => Effect.promise(() => value.close()),
  );
  const page = yield* Effect.promise(() => browser.newPage());
  const cdp = yield* Effect.promise(() => page.context().newCDPSession(page));
  yield* Effect.promise(() => page.setContent(html));
  let dialog: Dialog | undefined;
  page.on("dialog", (value) => {
    dialog = value;
  });
  const broker = yield* Broker.PreviewAutomationBroker;
  const connected = yield* Deferred.make<void>();
  let control: SessionControl | undefined;
  const operations: string[] = [];
  const events = yield* broker.connect({
    clientId: "real-page-fixture",
    environmentId: scope.environmentId,
    supportedOperations: [...PREVIEW_AUTOMATION_SERVER_OPERATIONS],
  });
  yield* Stream.runForEach(events, (event) =>
    Effect.gen(function* () {
      if (event.type === "connected") return yield* Deferred.succeed(connected, undefined);
      const request = event.request;
      operations.push(request.operation);
      control ??= new SessionControl(request.agentSessionId!, () => Page.invalidateRefs(page));
      const current = control;
      const run = async () => {
        switch (request.operation) {
          case "status":
            return { tabId };
          case "observe":
            return Page.observe(
              {
                page,
                cdp,
                includeImage: false,
                renderScale: 1,
                consoleEntries: [],
                networkEntries: [],
                actionTimeline: [],
              },
              request.agentSessionId,
            );
          case "type":
            await Page.type(page, decodeType(request.input));
            break;
          case "click":
            await Page.click(page, decodeClick(request.input));
            break;
          case "dialog": {
            if (!dialog) throw new Error("No pending dialog");
            const input = decodeDialog(request.input);
            await (input.accept ? dialog.accept(input.promptText) : dialog.dismiss());
            dialog = undefined;
            break;
          }
          case "waitFor":
            await Page.waitFor(page, decodeWait(request.input));
            break;
          default:
            throw new Error("Unexpected fixture operation");
        }
        return {};
      };
      const result = yield* Effect.result(
        Effect.tryPromise({
          try: () =>
            ["status", "observe"].includes(request.operation)
              ? current.observe(run)
              : current.agent(request.agentSessionId!, run),
          catch: Page.toOperationError,
        }),
      );
      if (request.operation === takeOverAfter) yield* Effect.promise(() => current.take("human"));
      yield* broker.respond({
        clientId: "real-page-fixture",
        connectionId: event.connectionId,
        requestId: request.requestId,
        ...(Result.isSuccess(result)
          ? { ok: true as const, result: result.success }
          : {
              ok: false as const,
              error: { _tag: result.failure.tag, message: result.failure.message },
            }),
      });
    }),
  ).pipe(Effect.forkScoped);
  yield* Deferred.await(connected);
  return { page, operations };
});

it.live.each([false, true])(
  "runs real form controls and respects a takeover between steps (takeover=%s)",
  (takeover) =>
    Effect.gen(function* () {
      const { page, operations } = yield* hostPage(
        `<label>Name<input id="name"></label>
    <button id="save" onclick="if(confirm('Save?')) setTimeout(() => document.querySelector('#result').textContent='Saved '+document.querySelector('#name').value, 30)">Save</button><p id="result">Waiting</p>`,
        takeover ? "type" : undefined,
      );
      const executor = yield* BrowserExecutor.BrowserExecutor;
      const bound = yield* executor.execute(scope, {
        steps: [{ op: "bind", tab: "app", input: { tabId } }],
      });
      const result = yield* executor.execute(scope, {
        sessionId: bound.sessionId,
        steps: [
          { op: "type", tab: "app", input: { locator: "#name", text: "Ada", clear: true } },
          { op: "click", tab: "app", input: { locator: "#save" } },
          { op: "dialog", tab: "app", input: { accept: true } },
          { op: "waitFor", tab: "app", input: { text: "Saved Ada" } },
        ],
      });
      expect(yield* Effect.promise(() => page.locator("#name").inputValue())).toBe("Ada");
      expect(result.completed).toBe(takeover ? 1 : 4);
      expect(result.observation?.state.mode).toBe("full");
      expect(yield* Effect.promise(() => page.locator("#result").textContent())).toBe(
        takeover ? "Waiting" : "Saved Ada",
      );
      if (takeover) {
        expect(result.error?.code).toBe("PreviewAutomationControlInterruptedError");
        expect(operations).not.toContain("dialog");
        expect(operations).not.toContain("waitFor");
      } else expect(result.error).toBeUndefined();
    }).pipe(Effect.scoped, Effect.provide(layer)),
);

const SETTINGS = `<h1 id="title">Settings</h1><div id="menu"></div>
<script>
const screens = { Settings: ["Account", "Billing", "Delete workspace"], Account: ["Profile", "Security"], Security: [] };
const show = (name) => {
  document.querySelector("#title").textContent = name;
  document.querySelector("#menu").replaceChildren(...screens[name].map((label) => {
    const button = document.createElement("button");
    button.textContent = label;
    button.onclick = () => screens[label] && show(label);
    return button;
  }));
};
show("Settings");
</script>`;

/** Walks Settings > Account > Security, as Jev would, and records every option it was offered. */
const scriptedDecider = (confidence: number, offered: string[]) =>
  Layer.succeed(
    BrowserGoal.GoalDecider,
    BrowserGoal.GoalDecider.of({
      decide: ({ page, options }) =>
        Effect.sync(() => {
          offered.push(...Object.values(options));
          if (page.includes('heading "Security"')) return { choice: "DONE", confidence };
          const next = page.includes('heading "Account"') ? "Security" : "Account";
          const choice = Object.keys(options).find(
            (id) => options[id] === `Click button "${next}"`,
          )!;
          return { choice, confidence };
        }),
    }),
  );

it.live.each([
  { confidence: 0.9, minConfidence: undefined, status: "needs_verification", heading: "Security" },
  { confidence: 0.3, minConfidence: undefined, status: "low_confidence", heading: "Settings" },
  { confidence: 0.3, minConfidence: 0.25, status: "needs_verification", heading: "Security" },
] as const)(
  "a goal step clicks through real pages until the decider is done or unsure ($status, $minConfidence)",
  ({ confidence, minConfidence, status, heading }) => {
    const offered: string[] = [];
    return Effect.gen(function* () {
      const { page } = yield* hostPage(SETTINGS);
      const executor = yield* BrowserExecutor.BrowserExecutor;
      const bound = yield* executor.execute(scope, {
        steps: [{ op: "bind", tab: "app", input: { tabId } }],
      });
      const result = yield* executor.execute(scope, {
        sessionId: bound.sessionId,
        steps: [
          {
            op: "goal",
            tab: "app",
            input: { goal: "Open security settings", deny: ["delete"], minConfidence },
          },
        ],
      });
      expect(yield* Effect.promise(() => page.locator("#title").textContent())).toBe(heading);
      expect(result.goals?.map((goal) => [goal.status, goal.actions])).toEqual([
        [
          status,
          status === "needs_verification"
            ? [
                `Click button "Account" (${confidence.toFixed(2)})`,
                `Click button "Security" (${confidence.toFixed(2)})`,
              ]
            : [],
        ],
      ]);
      expect(result.error).toEqual(
        status === "needs_verification"
          ? undefined
          : { step: 0, code: "goal_low_confidence", actionMayHaveRun: false },
      );
      expect(offered).toContain('Click button "Billing"');
      expect(offered).not.toContain('Click button "Delete workspace"');
    }).pipe(Effect.scoped, Effect.provide(executorLayer(scriptedDecider(confidence, offered))));
  },
);

it.live("a goal step counts a new title or URL as progress when the tree stays the same", () =>
  Effect.gen(function* () {
    // Like a Slack channel switch whose message pane falls past the tree budget.
    const { page } = yield* hostPage(
      `<title>Inbox</title><nav><button onmousedown="event.preventDefault()" onclick="document.title='zeus'; location.hash='zeus'">zeus</button></nav>`,
    );
    const executor = yield* BrowserExecutor.BrowserExecutor;
    const bound = yield* executor.execute(scope, {
      steps: [{ op: "bind", tab: "app", input: { tabId } }],
    });
    const result = yield* executor.execute(scope, {
      sessionId: bound.sessionId,
      steps: [{ op: "goal", tab: "app", input: { goal: "Open the zeus channel" } }],
    });
    expect(yield* Effect.promise(() => page.title())).toBe("zeus");
    expect(result.goals?.map((goal) => goal.status)).toEqual(["needs_verification"]);
  }).pipe(
    Effect.scoped,
    Effect.provide(
      executorLayer(
        Layer.succeed(
          BrowserGoal.GoalDecider,
          BrowserGoal.GoalDecider.of({
            decide: ({ page, options }) =>
              Effect.sync(() =>
                page.startsWith("Page: zeus")
                  ? { choice: "DONE", confidence: 1 }
                  : {
                      choice: Object.keys(options).find(
                        (id) => options[id] === 'Click button "zeus"',
                      )!,
                      confidence: 1,
                    },
              ),
          }),
        ),
      ),
    ),
  ),
);
