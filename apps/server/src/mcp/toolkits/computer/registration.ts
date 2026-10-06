import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { McpSchema, McpServer, Tool } from "effect/ai";
import * as ComputerUse from "../../../computerUse/ComputerUse.ts";
import { ComputerUseError } from "../../../computerUse/protocol.ts";
import { formatSnapshot } from "../../../computerUse/snapshotTree.ts";
import * as McpInvocationContext from "../../McpInvocationContext.ts";
import * as Handlers from "./handlers.ts";
import {
  ComputerActionTool,
  ComputerOpenTool,
  ComputerSnapshotTool,
  ComputerToolkit,
} from "./tools.ts";

type Content = McpSchema.CallToolResult["content"][number];
const imageContent = (observation: ComputerUse.Observation): Content[] =>
  observation.image
    ? [
        {
          type: "image",
          data: new Uint8Array(Buffer.from(observation.image.data, "base64")),
          mimeType: observation.image.mimeType,
        },
      ]
    : [];
const observationContent = (observation: ComputerUse.Observation): Content[] => [
  { type: "text", text: formatSnapshot(observation, observation.snapshotId) },
  ...imageContent(observation),
];

/** One line per completed step, then why the batch stopped, then the app as it is now. */
export function actionContent(result: ComputerUse.ActResult): Content[] {
  const lines = [
    `Completed ${result.completed.length} of ${result.total} steps${
      result.completed.length ? ` (${result.completed.join(", ")})` : ""
    }.`,
  ];
  if (result.error)
    lines.push(`Step ${result.completed.length + 1} stopped the batch: ${result.error.message}`);
  if (result.snapshotError) lines.push(`No fresh snapshot: ${result.snapshotError.message}`);
  return result.snapshot
    ? [
        {
          type: "text",
          text: `${lines.join("\n")}\n\n${formatSnapshot(result.snapshot, result.snapshot.snapshotId)}`,
        },
        ...imageContent(result.snapshot),
      ]
    : [{ type: "text", text: lines.join("\n") }];
}

/**
 * Registers a tool whose result carries text and images. The MCP runner
 * supplies invocation scope dynamically, alongside its declared request
 * context. Capture it just as the preview image tools do.
 */
const customTool = <T extends Tool.Any>(
  tool: T,
  annotations: McpSchema.Tool["annotations"],
  run: (
    computer: ComputerUse.ComputerUse["Service"],
    caller: string,
    input: Tool.Parameters<T>,
  ) => Effect.Effect<{ content: Content[]; isError?: boolean }, ComputerUseError>,
) =>
  Layer.effectDiscard(
    Effect.gen(function* () {
      const computer = yield* ComputerUse.ComputerUse;
      const server = yield* McpServer.McpServer;
      const decode = Schema.decodeUnknownEffect(
        tool.parametersSchema as Schema.Codec<Tool.Parameters<T>, unknown>,
      );
      yield* server.addTool({
        tool: new McpSchema.Tool({
          name: tool.name,
          description: Tool.getDescription(tool),
          inputSchema: Tool.getJsonSchema(tool),
          annotations,
        }),
        annotations: tool.annotations,
        handle: (payload) =>
          Effect.withFiber((fiber) => {
            const invocation = Context.getOption(
              fiber.context,
              McpInvocationContext.McpInvocationContext,
            );
            return Effect.gen(function* () {
              if (Option.isNone(invocation))
                return yield* new ComputerUseError({ code: "disabled" });
              const id = yield* Handlers.caller.pipe(
                Effect.provideService(McpInvocationContext.McpInvocationContext, invocation.value),
              );
              const input = yield* decode(payload).pipe(
                Effect.mapError(() => new ComputerUseError({ code: "invalid_input" })),
              );
              const result = yield* run(computer, id, input);
              return new McpSchema.CallToolResult({
                isError: result.isError ?? false,
                content: result.content,
              });
            }).pipe(
              Effect.catch((error) =>
                Effect.succeed(
                  new McpSchema.CallToolResult({
                    isError: true,
                    content: [{ type: "text", text: error.message }],
                  }),
                ),
              ),
            );
          }),
      });
    }),
  );

export const layer = Layer.mergeAll(
  McpServer.toolkit(ComputerToolkit).pipe(Layer.provide(Handlers.layer)),
  customTool(
    ComputerSnapshotTool,
    {
      title: "Inspect computer app",
      readOnlyHint: true,
      destructiveHint: false,
      openWorldHint: true,
    },
    (computer, caller, input) =>
      computer
        .snapshot(caller, { ...input, includeImage: input.includeImage ?? false })
        .pipe(Effect.map((observation) => ({ content: observationContent(observation) }))),
  ),
  customTool(
    ComputerActionTool,
    {
      title: "Control computer app",
      readOnlyHint: false,
      destructiveHint: true,
      openWorldHint: true,
    },
    (computer, caller, input) =>
      computer.act(caller, input).pipe(
        Effect.map((result) => ({
          content: actionContent(result),
          isError: result.error !== undefined && result.completed.length === 0,
        })),
      ),
  ),
  customTool(
    ComputerOpenTool,
    {
      title: "Open computer app",
      readOnlyHint: false,
      destructiveHint: false,
      openWorldHint: true,
    },
    (computer, caller, input) =>
      computer.open(caller, { app: input.app, activate: input.activate ?? false }).pipe(
        Effect.map((observation) => ({
          content: [
            {
              type: "text" as const,
              text: `Opened ${input.app}${input.activate ? " in front" : " in the background"}.`,
            },
            ...observationContent(observation),
          ],
        })),
      ),
  ),
);
