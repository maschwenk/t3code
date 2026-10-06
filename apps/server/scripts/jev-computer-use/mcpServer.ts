// @effect-diagnostics nodeBuiltinImport:off globalDate:off globalConsole:off preferSchemaOverJson:off globalErrorInEffectFailure:off anyUnknownInErrorContext:off - Experiment harness run directly with node.
/**
 * Stdio MCP server exposing T3's computer_snapshot and computer_action (same
 * descriptions, schemas and output text as the real server) over the fixture
 * app, plus computer_delegate when JEV_DELEGATE=1. Each run starts from the
 * fixture's initial state. Tool timings go to JEV_BENCH_LOG as JSON lines.
 *
 * Env: JEV_FIXTURE_STATE, JEV_BENCH_LOG, JEV_DELEGATE, JEV_CONFIG, JEV_MODEL, JEV_NATIVE_MS.
 */
import * as NodeFS from "node:fs";
import * as NodeReadline from "node:readline";
import * as NodeServices from "@effect/platform-node/NodeServices";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as ManagedRuntime from "effect/ManagedRuntime";
import * as Schema from "effect/Schema";
import { Tool } from "effect/ai";
import * as ComputerUse from "../../src/computerUse/ComputerUse.ts";
import * as Jev from "../../src/computerUse/jevDelegate.ts";
import { formatSnapshot } from "../../src/computerUse/snapshotTree.ts";
import { actionContent } from "../../src/mcp/toolkits/computer/registration.ts";
import { ComputerActionTool, ComputerSnapshotTool } from "../../src/mcp/toolkits/computer/tools.ts";
import * as DesktopTelemetryReceiver from "../../src/resourceTelemetry/DesktopTelemetryReceiver.ts";
import * as ServerSettings from "../../src/serverSettings.ts";
import * as Fixture from "./fixtureApp.ts";

const env = process.env;
const CALLER = "bench";

export const computerLayer = (options: Parameters<typeof Fixture.layer>[0]) =>
  ComputerUse.layer.pipe(
    Layer.provide(Fixture.layer(options)),
    Layer.provide(DesktopTelemetryReceiver.layerTest()),
    // Only the fixture is allowed; the settings checks still run on every call.
    Layer.provide(
      ServerSettings.layerTest({
        enableAgentComputerAccess: true,
        computerUseAllowAllApps: false,
        computerUseAllowedApps: [Fixture.APP],
      }),
    ),
    Layer.provide(NodeServices.layer),
  );

export const DELEGATE_TOOL = {
  name: "computer_delegate",
  description: [
    "Hand mechanical navigation in one app to a fast press-only operator. Give the app and a concrete goal that states the expected final state. It loops on fresh accessibility state and presses uniquely named buttons, checkboxes and tabs (about half a second per press), and stops when it judges the goal reached, when the goal needs text entry or anything else it cannot do, or when it is unsure.",
    "It never types, reads images or writes text. Use it for multi-screen navigation where the next control only appears after the previous press. Enter text with computer_action yourself (before or after delegating), and batch steps you can already plan from one snapshot with computer_action.",
    "Returns its decisions and the app's fresh snapshot with a snapshotId you can act on. Its result is unverified: check the snapshot yourself before reporting success.",
  ].join("\n\n"),
  inputSchema: {
    type: "object",
    properties: {
      app: { type: "string", description: "Exact app name, as for computer_snapshot." },
      goal: { type: "string", description: "What to achieve and the expected final state." },
      deny: {
        type: "array",
        items: { type: "string" },
        description: "Words in control names it must never press, for example Delete or Send.",
      },
    },
    required: ["app", "goal"],
    additionalProperties: false,
  },
};

const log = (entry: object) => {
  if (env.JEV_BENCH_LOG)
    NodeFS.appendFileSync(env.JEV_BENCH_LOG, `${JSON.stringify({ at: Date.now(), ...entry })}\n`);
};

async function main() {
  const stats = { requests: 0 };
  const runtime = ManagedRuntime.make(
    computerLayer({
      stats,
      nativeMs: Number(env.JEV_NATIVE_MS ?? 0),
      ...(env.JEV_FIXTURE_STATE ? { statePath: env.JEV_FIXTURE_STATE } : {}),
    }),
  );
  const computer = await runtime.runPromise(Effect.service(ComputerUse.ComputerUse));
  const delegateEnabled = env.JEV_DELEGATE === "1";
  const jevConfig = delegateEnabled
    ? await Effect.runPromise(
        Jev.loadJevConfig(env.JEV_CONFIG!, env.JEV_MODEL ? { model: env.JEV_MODEL } : {}),
      )
    : undefined;
  const t3Tool = (tool: typeof ComputerSnapshotTool | typeof ComputerActionTool) => ({
    name: tool.name,
    description: Tool.getDescription(tool),
    inputSchema: Tool.getJsonSchema(tool),
  });
  const tools = [
    t3Tool(ComputerSnapshotTool),
    t3Tool(ComputerActionTool),
    ...(delegateEnabled ? [DELEGATE_TOOL] : []),
  ];
  const decodeSnapshot = Schema.decodeUnknownEffect(ComputerSnapshotTool.parametersSchema);
  const decodeAction = Schema.decodeUnknownEffect(ComputerActionTool.parametersSchema);

  const call = (
    name: string,
    args: unknown,
  ): Effect.Effect<{ text: string; isError: boolean; meta?: object }, unknown> => {
    switch (name) {
      case "computer_snapshot":
        return decodeSnapshot(args).pipe(
          Effect.flatMap((input) => computer.snapshot(CALLER, { ...input, includeImage: false })),
          Effect.map((observation) => ({
            text: formatSnapshot(observation, observation.snapshotId),
            isError: false,
          })),
        );
      case "computer_action":
        return decodeAction(args).pipe(
          Effect.flatMap((input) => computer.act(CALLER, { ...input, includeImage: false })),
          Effect.map((result) => {
            const [first] = actionContent(result);
            return {
              text: first?.type === "text" ? first.text : "",
              isError: result.error !== undefined && result.completed.length === 0,
              meta: { steps: result.total, completed: result.completed.length },
            };
          }),
        );
      case "computer_delegate": {
        const input = args as { app: string; goal: string; deny?: string[] };
        return Jev.delegate(
          computer,
          (request) => Jev.decide(jevConfig!, request),
          CALLER,
          input,
        ).pipe(
          Effect.map((result) => ({
            text: Jev.delegateSummary(result, (o) => formatSnapshot(o, o.snapshotId)),
            isError: false,
            meta: {
              status: result.status,
              decisions: result.steps.length,
              jevMs: result.steps.reduce((sum, step) => sum + step.jevMs, 0),
              actMs: result.steps.reduce((sum, step) => sum + (step.actMs ?? 0), 0),
              jevCostUsd: result.steps.reduce((sum, step) => sum + (step.costUsd ?? 0), 0),
              jevInputTokens: result.steps.reduce((sum, step) => sum + (step.inputTokens ?? 0), 0),
            },
          })),
        );
      }
      default:
        return Effect.fail(new Error(`Unknown tool ${name}`));
    }
  };

  const send = (message: object) =>
    process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
  const lines = NodeReadline.createInterface({ input: process.stdin });
  for await (const line of lines) {
    if (!line.trim()) continue;
    const message = JSON.parse(line) as { id?: number | string; method: string; params?: any };
    if (message.id === undefined) continue;
    if (message.method === "initialize")
      send({
        id: message.id,
        result: {
          protocolVersion: message.params?.protocolVersion ?? "2025-06-18",
          capabilities: { tools: {} },
          serverInfo: { name: "t3-computer-bench", version: "0" },
        },
      });
    else if (message.method === "tools/list") send({ id: message.id, result: { tools } });
    else if (message.method === "tools/call") {
      const { name, arguments: args } = message.params;
      const startedAt = performance.now();
      const requestsBefore = stats.requests;
      const outcome = await runtime.runPromise(
        call(name, args).pipe(
          Effect.catch((error: unknown) =>
            Effect.succeed({
              text: error instanceof Error ? error.message : String(error),
              isError: true,
              meta: { error: (error as { code?: string })?.code ?? "error" },
            }),
          ),
        ),
      );
      log({
        tool: name,
        ms: Math.round(performance.now() - startedAt),
        native: stats.requests - requestsBefore,
        isError: outcome.isError,
        ...outcome.meta,
      });
      send({
        id: message.id,
        result: { content: [{ type: "text", text: outcome.text }], isError: outcome.isError },
      });
    } else if (message.method === "ping") send({ id: message.id, result: {} });
    else send({ id: message.id, error: { code: -32601, message: "Method not found" } });
  }
  await runtime.dispose();
}

if (import.meta.main) await main();
