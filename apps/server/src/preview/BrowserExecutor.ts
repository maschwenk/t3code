import {
  type BrowserExecutorInput,
  type BrowserExecutorResult,
  OrchestratorMcpFailure,
  PreviewAutomationClickInput,
  PreviewAutomationDialogInput,
  PreviewAutomationHoverInput,
  PreviewAutomationNavigateInput,
  PreviewAutomationObservation,
  PreviewAutomationOpenInput,
  PreviewAutomationPressInput,
  PreviewAutomationScrollInput,
  PreviewAutomationSelectInput,
  PreviewAutomationTypeInput,
  PreviewAutomationWaitForInput,
  PreviewTabId,
  type PreviewAutomationStatus,
} from "@t3tools/contracts";
import * as Clock from "effect/Clock";
import * as Context from "effect/Context";
import * as Crypto from "effect/Crypto";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Result from "effect/Result";
import * as Schema from "effect/Schema";
import * as Semaphore from "effect/Semaphore";
import type { McpThreadInvocationScope } from "../mcp/McpInvocationContext.ts";
import * as Broker from "../mcp/PreviewAutomationBroker.ts";

export class BrowserExecutor extends Context.Service<
  BrowserExecutor,
  {
    readonly execute: (
      scope: McpThreadInvocationScope,
      input: BrowserExecutorInput,
    ) => Effect.Effect<BrowserExecutorResult, OrchestratorMcpFailure>;
  }
>()("t3/preview/BrowserExecutor") {}

const step = <const Op extends string, S extends Schema.Top>(op: Op, input: S) =>
  Schema.Struct({ op: Schema.Literal(op), tab: Schema.String, input });
// Reuse the individual tools' validators without repeating their schemas in the
// executor's tool definition. The entire program is decoded before its first write.
const decodeSteps = Schema.decodeUnknownResult(
  Schema.Array(
    Schema.Union([
      step("open", PreviewAutomationOpenInput),
      step("bind", Schema.Struct({ tabId: PreviewTabId })),
      step("navigate", PreviewAutomationNavigateInput),
      step("click", PreviewAutomationClickInput),
      step("type", PreviewAutomationTypeInput),
      step("press", PreviewAutomationPressInput),
      step("scroll", PreviewAutomationScrollInput),
      step("hover", PreviewAutomationHoverInput),
      step("select", PreviewAutomationSelectInput),
      step("dialog", PreviewAutomationDialogInput),
      step("waitFor", PreviewAutomationWaitForInput),
      step("close", Schema.Struct({})),
    ]),
  ),
);
const decodeObservation = Schema.decodeUnknownResult(PreviewAutomationObservation);
const isTabId = Schema.is(PreviewTabId);
const invalid = (message: string) =>
  new OrchestratorMcpFailure({ code: "invalid_request", message });
const ownerOf = (scope: McpThreadInvocationScope) =>
  JSON.stringify([
    scope.environmentId,
    scope.thread.threadId,
    scope.thread.providerInstanceId,
    scope.thread.providerSessionId,
    scope.requestNamespace,
    scope.client?.sessionId,
  ]);

type Session = {
  owner: string;
  tabs: Map<string, PreviewTabId>;
  current: string | undefined;
  at: number;
  active: number;
  interrupted: boolean;
  mutex: Semaphore.Semaphore;
};

const make = Effect.gen(function* () {
  const broker = yield* Broker.PreviewAutomationBroker;
  const crypto = yield* Crypto.Crypto;
  const sessions = new Map<string, Session>();
  const execute = Effect.fn("BrowserExecutor.execute")(function* (
    scope: McpThreadInvocationScope,
    input: BrowserExecutorInput,
  ) {
    if (input.steps.length > 20 || (input.reset && (!input.sessionId || input.steps.length)))
      return yield* invalid(
        "Use at most 20 steps. Reset requires sessionId and an empty steps array.",
      );
    const decoded = decodeSteps(input.steps.map((item) => ({ ...item, input: item.input ?? {} })));
    if (Result.isFailure(decoded))
      return yield* invalid(
        "Invalid step input. Use the corresponding preview tool's input fields; no actions ran.",
      );
    const owner = ownerOf(scope);
    const now = yield* Clock.currentTimeMillis;
    for (const [id, session] of sessions)
      if (session.active === 0 && now - session.at > 30 * 60_000) sessions.delete(id);
    let sessionId = input.sessionId;
    let session = sessionId === undefined ? undefined : sessions.get(sessionId);
    if (sessionId !== undefined && (!session || session.owner !== owner))
      return yield* invalid(
        "Executor session expired or belongs to another caller. Start a new session and bind its tabs explicitly.",
      );
    if (!session) {
      if (
        sessions.size >= 64 ||
        [...sessions.values()].filter((value) => value.owner === owner).length >= 4
      )
        return yield* invalid("Executor session limit reached. Reset an unused session first.");
      sessionId = yield* crypto
        .randomUUIDv4()
        .pipe(Effect.mapError(() => invalid("Could not create executor session.")));
      session = {
        owner,
        tabs: new Map(),
        current: undefined,
        at: now,
        active: 0,
        interrupted: false,
        mutex: Semaphore.makeUnsafe(1),
      };
      sessions.set(sessionId, session);
    }
    const state = session;
    const id = sessionId!;
    state.active++;
    return yield* state.mutex
      .withPermits(1)(
        Effect.gen(function* () {
          if (sessions.get(id) !== state)
            return yield* invalid("Executor session was reset. Start a new session.");
          if (input.reset) {
            sessions.delete(id);
            return { sessionId: id, tabs: [], completed: 0, reset: true };
          }
          if (state.interrupted && decoded.success.length)
            return yield* invalid(
              "The previous batch was interrupted and a write may have happened. Run empty steps to inspect the tab before continuing.",
            );
          // Validate handle flow before opening or mutating any page.
          const names = new Set(state.tabs.keys());
          for (const item of decoded.success) {
            if (item.op === "open" || item.op === "bind") {
              if (names.has(item.tab) || names.size >= 8)
                return yield* invalid(
                  "Tab names must be new, with at most eight per session. Close a handle before reusing its name.",
                );
              names.add(item.tab);
            } else {
              if (!names.has(item.tab))
                return yield* invalid("Unknown tab name. Open or bind it before acting.");
              if (item.op === "close") names.delete(item.tab);
            }
            if (item.op !== "bind" && "tabId" in item.input && item.input.tabId !== undefined)
              return yield* invalid(
                "Steps target their named tab. Use bind with tabId to attach an existing tab.",
              );
          }
          if (input.observeTab && !names.has(input.observeTab))
            return yield* invalid("The observation tab must remain open at the end of the batch.");
          const deadline = (yield* Clock.currentTimeMillis) + 60_000;
          let completed = 0;
          let error: BrowserExecutorResult["error"];
          let observation: BrowserExecutorResult["observation"];
          let observationError: BrowserExecutorResult["observationError"];
          for (const item of decoded.success) {
            const remaining = deadline - (yield* Clock.currentTimeMillis);
            if (remaining <= 0) {
              error = { step: completed, code: "deadline_exceeded", actionMayHaveRun: false };
              break;
            }
            const tabId =
              item.op === "open"
                ? undefined
                : item.op === "bind"
                  ? item.input.tabId
                  : state.tabs.get(item.tab)!;
            if (tabId) state.current = item.tab;
            const timeoutMs = Math.min(
              remaining,
              item.op === "open"
                ? 60_000
                : "timeoutMs" in item.input
                  ? (item.input.timeoutMs ?? 15_000)
                  : 15_000,
            );
            const operation = item.op === "bind" ? "status" : item.op;
            const payload =
              item.op === "open"
                ? {
                    ...item.input,
                    ...(item.input.open === undefined && item.input.show === undefined
                      ? {}
                      : { open: item.input.open ?? item.input.show }),
                    reuseExistingTab: false,
                  }
                : { ...item.input, timeoutMs };
            const outcome = yield* Effect.result(
              broker.invoke<PreviewAutomationStatus>({
                scope,
                operation,
                input: payload,
                ...(tabId ? { tabId } : {}),
                timeoutMs,
              }),
            );
            if (Result.isFailure(outcome)) {
              error = {
                step: completed,
                code: outcome.failure._tag,
                actionMayHaveRun: !["bind", "waitFor"].includes(item.op),
              };
              break;
            }
            if (item.op === "open" || item.op === "bind") {
              const resolved = outcome.success?.tabId;
              if (!isTabId(resolved) || (tabId !== undefined && resolved !== tabId)) {
                error = {
                  step: completed,
                  code: "invalid_tab_response",
                  actionMayHaveRun: item.op === "open",
                };
                break;
              }
              state.tabs.set(item.tab, resolved);
              state.current = item.tab;
            } else if (item.op === "close") {
              state.tabs.delete(item.tab);
              if (state.current === item.tab) state.current = undefined;
            }
            completed++;
          }
          const target = input.observeTab ?? state.current;
          const tabId = target === undefined ? undefined : state.tabs.get(target);
          if (target && tabId) {
            const remaining = deadline - (yield* Clock.currentTimeMillis);
            if (remaining <= 0) observationError = { tab: target, code: "deadline_exceeded" };
            else {
              const read = yield* Effect.result(
                broker.invoke({
                  scope,
                  operation: "observe",
                  tabId,
                  input: input.baselineId === undefined ? {} : { baselineId: input.baselineId },
                  timeoutMs: Math.min(remaining, 12_000),
                }),
              );
              if (Result.isFailure(read))
                observationError = { tab: target, code: read.failure._tag };
              else {
                const decoded = decodeObservation(read.success);
                if (Result.isFailure(decoded))
                  observationError = { tab: target, code: "invalid_observation_response" };
                else {
                  observation = { tab: target, state: decoded.success };
                  state.interrupted = false;
                }
              }
            }
          }
          state.at = yield* Clock.currentTimeMillis;
          if (error?.actionMayHaveRun && !observation) state.interrupted = true;
          return {
            sessionId: id,
            tabs: [...state.tabs].map(([name, tabId]) => ({ name, tabId })),
            completed,
            ...(error ? { error } : {}),
            ...(observation ? { observation } : {}),
            ...(observationError ? { observationError } : {}),
          };
        }),
      )
      .pipe(
        Effect.onError(() =>
          Effect.sync(() => {
            if (input.sessionId === undefined) sessions.delete(id);
          }),
        ),
        Effect.onInterrupt(() =>
          Effect.sync(() => {
            state.interrupted = true;
          }),
        ),
        Effect.ensuring(
          Effect.sync(() => {
            state.active--;
          }),
        ),
      );
  });
  return BrowserExecutor.of({ execute });
});
export const layer = Layer.effect(BrowserExecutor, make);
