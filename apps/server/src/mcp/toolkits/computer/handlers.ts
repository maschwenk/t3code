import * as Effect from "effect/Effect";
import * as ComputerUse from "../../../computerUse/ComputerUse.ts";
import { ComputerUseError } from "../../../computerUse/protocol.ts";
import * as McpInvocationContext from "../../McpInvocationContext.ts";
import { ComputerToolkit } from "./tools.ts";

// External OAuth callers have no thread and cannot reach the host computer.
export const caller = McpInvocationContext.requireMcpCapability("orchestration").pipe(
  Effect.flatMap((scope) => McpInvocationContext.requireThreadScope(scope, "computer use")),
  Effect.map(
    (scope) =>
      `${scope.environmentId}:${scope.thread.threadId}:${scope.thread.providerInstanceId}:${scope.thread.providerSessionId}`,
  ),
  Effect.mapError(() => new ComputerUseError({ code: "disabled" })),
);

export const layer = ComputerToolkit.toLayer({
  computer_status: () =>
    Effect.gen(function* () {
      yield* caller;
      return yield* (yield* ComputerUse.ComputerUse).status;
    }),
});
