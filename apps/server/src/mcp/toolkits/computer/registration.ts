import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { McpSchema, McpServer, Tool } from "effect/ai";
import * as ComputerUse from "../../../computerUse/ComputerUse.ts";
import { ComputerUseError } from "../../../computerUse/protocol.ts";
import * as McpInvocationContext from "../../McpInvocationContext.ts";
import * as Handlers from "./handlers.ts";
import { ComputerToolkit, ComputerSnapshotTool } from "./tools.ts";

const encodeJson = Schema.encodeSync(Schema.fromJsonString(Schema.Unknown));
const decodeSnapshotInput = Schema.decodeUnknownEffect(ComputerSnapshotTool.parametersSchema);
const layerSnapshot = Layer.effectDiscard(
  Effect.gen(function* () {
    const computer = yield* ComputerUse.ComputerUse;
    const server = yield* McpServer.McpServer;
    yield* server.addTool({
      tool: new McpSchema.Tool({
        name: ComputerSnapshotTool.name,
        description: Tool.getDescription(ComputerSnapshotTool),
        inputSchema: Tool.getJsonSchema(ComputerSnapshotTool),
        annotations: {
          title: "Inspect computer app",
          readOnlyHint: true,
          destructiveHint: false,
          openWorldHint: true,
        },
      }),
      annotations: ComputerSnapshotTool.annotations,
      // The MCP runner supplies invocation scope dynamically, alongside its
      // declared request context. Capture it just as the preview image tools do.
      handle: (payload) =>
        Effect.withFiber((fiber) => {
          const invocation = Context.getOption(
            fiber.context,
            McpInvocationContext.McpInvocationContext,
          );
          return Effect.gen(function* () {
            if (Option.isNone(invocation)) return yield* new ComputerUseError({ code: "disabled" });
            const id = yield* Handlers.caller.pipe(
              Effect.provideService(McpInvocationContext.McpInvocationContext, invocation.value),
            );
            const input = yield* decodeSnapshotInput(payload).pipe(
              Effect.mapError(() => new ComputerUseError({ code: "invalid_input" })),
            );
            const { image, elements, ...rest } = yield* computer.snapshot(id, {
              app: input.app,
              includeImage: input.includeImage ?? false,
            });
            const metadata = {
              ...rest,
              elements: elements.map(({ path: _path, stableId: _stableId, ...element }) => element),
              ...(image
                ? {
                    screenshot: {
                      mimeType: image.mimeType,
                      width: image.width,
                      height: image.height,
                    },
                  }
                : {}),
            };
            return new McpSchema.CallToolResult({
              isError: false,
              structuredContent: metadata,
              content: [
                { type: "text", text: encodeJson(metadata) },
                ...(image
                  ? [
                      {
                        type: "image" as const,
                        data: new Uint8Array(Buffer.from(image.data, "base64")),
                        mimeType: image.mimeType,
                      },
                    ]
                  : []),
              ],
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
  layerSnapshot,
);
