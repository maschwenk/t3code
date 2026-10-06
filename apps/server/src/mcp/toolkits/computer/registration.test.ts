import { expect, it } from "@effect/vitest";
import * as NodeServices from "@effect/platform-node/NodeServices";
import { EnvironmentId, ProviderInstanceId, ThreadId } from "@t3tools/contracts";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import { McpSchema, McpServer } from "effect/ai";
import * as ComputerUse from "../../../computerUse/ComputerUse.ts";
import * as Driver from "../../../computerUse/Driver.ts";
import type { WorkerRequest } from "../../../computerUse/protocol.ts";
import * as ServerSettings from "../../../serverSettings.ts";
import * as McpInvocationContext from "../../McpInvocationContext.ts";
import * as Registration from "./registration.ts";

const invocation: McpInvocationContext.McpInvocationScope = {
  environmentId: EnvironmentId.make("computer-test"),
  requestNamespace: "claude-test",
  issuedAt: 1,
  capabilities: new Set(["orchestration"]),
  thread: {
    threadId: ThreadId.make("thread-test"),
    providerSessionId: "claude-test",
    providerInstanceId: ProviderInstanceId.make("claude"),
  },
  client: undefined,
};
const client = McpSchema.McpServerClient.of({
  clientInfo: { name: "computer-test", version: "1" },
  clientId: 1,
  clientCapabilities: {},
  protocolVersion: "2025-06-18",
  initializePayload: {
    protocolVersion: "2025-06-18",
    capabilities: {},
    clientInfo: { name: "computer-test", version: "1" },
  },
  getClient: Effect.die("unused"),
});
const encodeJson = Schema.encodeSync(Schema.fromJsonString(Schema.Unknown));
const png =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9ZkAAAAASUVORK5CYII=";
const layerTest = (calls: WorkerRequest[]) =>
  Registration.layer.pipe(
    Layer.provideMerge(McpServer.McpServer.layer),
    Layer.provide(
      ComputerUse.layer.pipe(
        Layer.provide(
          Layer.succeed(Driver.Driver, {
            execute: (request) =>
              Effect.sync(() => {
                calls.push(request);
                return request.kind === "action"
                  ? { ok: true as const }
                  : {
                      ok: true as const,
                      snapshot: {
                        app: "Calculator",
                        pid: 42,
                        truncated: false,
                        elements: [
                          {
                            ref: 1,
                            role: "button",
                            name: "7",
                            value: null,
                            enabled: true,
                            editable: false,
                            actions: ["press"],
                            path: [0, 0],
                            stableId: "private-id",
                            bounds: { x: 0, y: 0, width: 30, height: 30 },
                          },
                        ],
                        ...(request.includeImage
                          ? {
                              image: {
                                data: png,
                                mimeType: "image/png" as const,
                                width: 1,
                                height: 1,
                              },
                            }
                          : {}),
                      },
                    };
              }),
          }),
        ),
      ),
    ),
    Layer.provideMerge(
      ServerSettings.layerTest({
        enableAgentComputerAccess: true,
        enableComputerScreenCapture: true,
        computerUseAllowedApps: ["Calculator"],
      }),
    ),
    Layer.provide(NodeServices.layer),
  );

it.effect("exposes Claude tools with image content and session-bound action receipts", () => {
  const calls: WorkerRequest[] = [];
  return Effect.gen(function* () {
    const server = yield* McpServer.McpServer;
    expect(server.tools.map(({ tool }) => tool.name).toSorted()).toEqual([
      "computer_action",
      "computer_snapshot",
      "computer_status",
    ]);
    const shot = yield* server.callTool({
      name: "computer_snapshot",
      arguments: { app: "Calculator", includeImage: true },
    });
    expect(shot.isError).toBe(false);
    expect(shot.content.map((item) => item.type)).toEqual(["text", "image"]);
    const metadata = shot.structuredContent as { snapshotId: string; elements: unknown[] };
    expect(metadata.elements[0]).not.toHaveProperty("path");
    expect(metadata.elements[0]).not.toHaveProperty("stableId");
    expect(encodeJson(metadata)).not.toContain(png);
    const args = {
      snapshotId: metadata.snapshotId,
      ref: 1,
      action: { kind: "click", button: "left", count: 1 },
    };
    const result = yield* server.callTool({ name: "computer_action", arguments: args });
    expect(result.isError).toBe(false);
    const duplicate = yield* server.callTool({ name: "computer_action", arguments: args });
    expect(duplicate.isError).toBe(true);
    expect(calls.filter((call) => call.kind === "action")).toHaveLength(1);
  }).pipe(
    Effect.provideService(McpInvocationContext.McpInvocationContext, invocation),
    Effect.provideService(McpSchema.McpServerClient, client),
    Effect.provide(layerTest(calls)),
  );
});

it.effect(
  "denies external callers, malformed input and revoked capture permission before native work",
  () => {
    const calls: WorkerRequest[] = [];
    return Effect.gen(function* () {
      const server = yield* McpServer.McpServer;
      const settings = yield* ServerSettings.ServerSettingsService;
      const external = yield* server
        .callTool({ name: "computer_snapshot", arguments: { app: "Calculator" } })
        .pipe(
          Effect.provideService(McpInvocationContext.McpInvocationContext, {
            ...invocation,
            thread: undefined,
          }),
        );
      expect(external.isError).toBe(true);
      const invalid = yield* server.callTool({ name: "computer_snapshot", arguments: { app: 42 } });
      expect(invalid.isError).toBe(true);
      yield* settings.updateSettings({ enableComputerScreenCapture: false });
      const denied = yield* server.callTool({
        name: "computer_snapshot",
        arguments: { app: "Calculator", includeImage: true },
      });
      expect(denied.isError).toBe(true);
      expect(calls).toHaveLength(0);
    }).pipe(
      Effect.provideService(McpInvocationContext.McpInvocationContext, invocation),
      Effect.provideService(McpSchema.McpServerClient, client),
      Effect.provide(layerTest(calls)),
    );
  },
);
