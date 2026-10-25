import * as NodeServices from "@effect/platform-node/NodeServices";
import { expect, it } from "@effect/vitest";
import {
  EnvironmentId,
  PreviewTabId,
  ProviderInstanceId,
  ThreadId,
  PREVIEW_AUTOMATION_SERVER_OPERATIONS,
  type PreviewAutomationRequest,
} from "@t3tools/contracts";
import * as Deferred from "effect/Deferred";
import * as Fiber from "effect/Fiber";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Stream from "effect/Stream";
import * as TestClock from "effect/testing/TestClock";
import * as Broker from "../mcp/PreviewAutomationBroker.ts";
import * as BrowserExecutor from "./BrowserExecutor.ts";

const scope = {
  environmentId: EnvironmentId.make("executor-env"),
  requestNamespace: "executor-session",
  thread: {
    threadId: ThreadId.make("executor-thread"),
    providerSessionId: "session",
    providerInstanceId: ProviderInstanceId.make("codex"),
  },
  client: undefined,
  capabilities: new Set(["preview"] as const),
  issuedAt: 1,
};
const tabId = PreviewTabId.make("executor-tab");
const layer = BrowserExecutor.layer.pipe(
  Layer.provideMerge(Broker.layer),
  Layer.provide(NodeServices.layer),
);
const setup = Effect.fn("BrowserExecutorTest.setup")(function* (
  fail?: string,
  blocked?: Deferred.Deferred<void>,
) {
  const broker = yield* Broker.PreviewAutomationBroker;
  const connected = yield* Deferred.make<void>();
  const requests: PreviewAutomationRequest[] = [];
  const events = yield* broker.connect({
    clientId: "executor-host",
    environmentId: scope.environmentId,
    supportedOperations: [...PREVIEW_AUTOMATION_SERVER_OPERATIONS],
  });
  yield* Stream.runForEach(events, (event) => {
    if (event.type === "connected") return Deferred.succeed(connected, undefined);
    requests.push(event.request);
    if (blocked && event.request.operation === "type") return Deferred.succeed(blocked, undefined);
    const response = {
      clientId: "executor-host",
      connectionId: event.connectionId,
      requestId: event.request.requestId,
    };
    return event.request.operation === fail
      ? broker.respond({
          ...response,
          ok: false,
          error: { _tag: "PreviewAutomationExecutionError", message: "private-page-error" },
        })
      : broker.respond({
          ...response,
          ok: true,
          result:
            event.request.operation === "observe"
              ? {
                  mode: "full",
                  revision: "r1",
                  refPrefix: "t3-r1-",
                  url: "https://example.test",
                  title: "Fixture",
                  loading: false,
                  readiness: "dom_quiet",
                  truncated: false,
                  tree: '- button "Save" [ref=e1]',
                }
              : { tabId },
        });
  }).pipe(Effect.forkScoped);
  yield* Deferred.await(connected);
  return { executor: yield* BrowserExecutor.BrowserExecutor, requests };
});

it.effect("retains named tabs across batches and returns only one final observation", () =>
  Effect.gen(function* () {
    const { executor, requests } = yield* setup();
    const first = yield* executor.execute(scope, {
      steps: [{ op: "open", tab: "app", input: { url: "https://example.test" } }],
    });
    const next = yield* executor.execute(scope, {
      sessionId: first.sessionId,
      baselineId: "r1",
      steps: [
        { op: "type", tab: "app", input: { locator: "#name", text: "Ada" } },
        { op: "click", tab: "app", input: { locator: "#save" } },
      ],
    });
    expect(next.completed).toBe(2);
    expect(next.observation?.state.mode).toBe("full");
    expect(requests.map((request) => request.operation)).toEqual([
      "open",
      "observe",
      "type",
      "click",
      "observe",
    ]);
    expect(requests.slice(1).every((request) => request.tabId === tabId)).toBe(true);
    expect(requests.at(-1)?.input).toEqual({ baselineId: "r1" });
  }).pipe(Effect.scoped, Effect.provide(layer)),
);

it.effect(
  "stops after an uncertain write and observes without replaying or leaking page errors",
  () =>
    Effect.gen(function* () {
      const { executor, requests } = yield* setup("click");
      const result = yield* executor.execute(scope, {
        steps: [
          { op: "open", tab: "app", input: {} },
          { op: "click", tab: "app", input: { locator: "#save" } },
          { op: "press", tab: "app", input: { key: "Enter" } },
        ],
      });
      expect(result.completed).toBe(1);
      expect(result.error).toMatchObject({ step: 1, actionMayHaveRun: true });
      expect(result.observation).toBeDefined();
      expect(requests.map((request) => request.operation)).toEqual(["open", "click", "observe"]);
      expect(JSON.stringify(result)).not.toContain("private-page-error");
    }).pipe(Effect.scoped, Effect.provide(layer)),
);

it.effect("rejects another caller, expired sessions and invalid programs before any writes", () =>
  Effect.gen(function* () {
    const { executor, requests } = yield* setup();
    const first = yield* executor.execute(scope, {
      steps: [{ op: "open", tab: "app", input: {} }],
    });
    const before = requests.length;
    const foreign = { ...scope, thread: { ...scope.thread, threadId: ThreadId.make("other") } };
    expect(
      (yield* Effect.result(executor.execute(foreign, { sessionId: first.sessionId, steps: [] })))
        ._tag,
    ).toBe("Failure");
    expect(
      (yield* Effect.result(
        executor.execute(scope, {
          steps: [
            { op: "open", tab: "app", input: {} },
            { op: "click", tab: "app", input: { x: 1 } },
          ],
        }),
      ))._tag,
    ).toBe("Failure");
    yield* TestClock.adjust("31 minutes");
    expect(
      (yield* Effect.result(executor.execute(scope, { sessionId: first.sessionId, steps: [] })))
        ._tag,
    ).toBe("Failure");
    expect(requests).toHaveLength(before);
  }).pipe(Effect.scoped, Effect.provide(layer)),
);

it.effect(
  "invalid handle programs do not exhaust session capacity, and reset forgets handles without closing tabs",
  () =>
    Effect.gen(function* () {
      const { executor, requests } = yield* setup();
      for (let i = 0; i < 5; i++) {
        expect(
          (yield* Effect.result(
            executor.execute(scope, {
              steps: [{ op: "click", tab: "missing", input: { locator: "#save" } }],
            }),
          ))._tag,
        ).toBe("Failure");
      }
      expect(requests).toHaveLength(0);
      const first = yield* executor.execute(scope, {
        steps: [{ op: "open", tab: "app", input: {} }],
      });
      expect(requests[0]?.input).toEqual({ reuseExistingTab: false });
      const reset = yield* executor.execute(scope, {
        sessionId: first.sessionId,
        reset: true,
        steps: [],
      });
      expect(reset.reset).toBe(true);
      expect(requests.map((request) => request.operation)).toEqual(["open", "observe"]);
      expect(
        (yield* Effect.result(executor.execute(scope, { sessionId: first.sessionId, steps: [] })))
          ._tag,
      ).toBe("Failure");
    }).pipe(Effect.scoped, Effect.provide(layer)),
);

it.effect.each(["interrupt", "deadline"] as const)(
  "requires fresh observation after a pending write loses its caller (%s)",
  (mode) =>
    Effect.gen(function* () {
      const blocked = yield* Deferred.make<void>();
      const { executor, requests } = yield* setup(undefined, blocked);
      const first = yield* executor.execute(scope, {
        steps: [{ op: "open", tab: "app", input: {} }],
      });
      const fiber = yield* executor
        .execute(scope, {
          sessionId: first.sessionId,
          steps: [
            { op: "type", tab: "app", input: { locator: "#name", text: "Ada", timeoutMs: 60_000 } },
            { op: "click", tab: "app", input: { locator: "#save" } },
          ],
        })
        .pipe(Effect.forkChild);
      yield* Deferred.await(blocked);
      if (mode === "interrupt") yield* Fiber.interrupt(fiber);
      else {
        yield* TestClock.adjust("61 seconds");
        const result = yield* Fiber.join(fiber);
        expect(result.completed).toBe(0);
        expect(result.error?.actionMayHaveRun).toBe(true);
        expect(result.observationError?.code).toBe("deadline_exceeded");
      }
      expect(
        (yield* Effect.result(
          executor.execute(scope, {
            sessionId: first.sessionId,
            steps: [{ op: "click", tab: "app", input: { locator: "#save" } }],
          }),
        ))._tag,
      ).toBe("Failure");
      if (mode === "deadline") yield* setup();
      const refreshed = yield* executor.execute(scope, { sessionId: first.sessionId, steps: [] });
      expect(refreshed.observation).toBeDefined();
      expect(requests.filter((request) => request.operation === "type")).toHaveLength(1);
      expect(requests.filter((request) => request.operation === "click")).toHaveLength(0);
    }).pipe(Effect.scoped, Effect.provide(layer)),
);
