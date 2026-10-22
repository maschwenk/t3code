import * as Effect from "effect/Effect";
import * as ComputerUse from "../../../computerUse/ComputerUse.ts";
import { ComputerUseError } from "../../../computerUse/protocol.ts";
import * as McpInvocationContext from "../../McpInvocationContext.ts";
import * as McpToolAccess from "../../McpToolAccess.ts";
import { ComputerContentToolkit, ComputerToolkit } from "./tools.ts";

// External OAuth callers have no thread and cannot reach the host computer.
const caller = McpInvocationContext.requireMcpCapability("orchestration").pipe(
  Effect.flatMap((scope) => McpInvocationContext.requireThreadScope(scope, "computer use")),
  Effect.map(
    (scope) =>
      `${scope.environmentId}:${scope.thread.threadId}:${scope.thread.providerInstanceId}:${scope.thread.providerSessionId}`,
  ),
  Effect.mapError(() => new ComputerUseError({ code: "disabled" })),
);

// Every computer tool needs a thread credential (`readsAsCaller`), but none loads
// the calling thread: what an agent may do on the host is decided by the computer
// use settings (enabled, allowed apps, screen capture) that ComputerUse enforces,
// and the dev harness acts as a thread that has no record to load.
export const layer = McpToolAccess.toLayer(ComputerToolkit, {
  computer_status: McpToolAccess.readsAsCaller(() =>
    Effect.gen(function* () {
      yield* caller;
      return yield* (yield* ComputerUse.ComputerUse).status;
    }),
  ),
});

export const layerContent = McpToolAccess.toLayer(ComputerContentToolkit, {
  computer_snapshot: McpToolAccess.readsAsCaller((input) =>
    Effect.gen(function* () {
      const id = yield* caller;
      return yield* (yield* ComputerUse.ComputerUse).snapshot(id, {
        ...input,
        includeImage: input.includeImage ?? false,
      });
    }),
  ),
  computer_action: McpToolAccess.readsAsCaller((input) =>
    Effect.gen(function* () {
      const id = yield* caller;
      return yield* (yield* ComputerUse.ComputerUse).act(id, input);
    }),
  ),
  computer_open: McpToolAccess.readsAsCaller((input) =>
    Effect.gen(function* () {
      const id = yield* caller;
      return yield* (yield* ComputerUse.ComputerUse).open(id, {
        app: input.app,
        activate: input.activate ?? false,
      });
    }),
  ),
});
