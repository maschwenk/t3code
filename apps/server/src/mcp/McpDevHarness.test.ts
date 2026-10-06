import { expect, it } from "@effect/vitest";
import { NodeHttpServer } from "@effect/platform-node";
import * as NodeServices from "@effect/platform-node/NodeServices";
import {
  AuthAdministrativeScopes,
  AuthSessionId,
  AuthStandardClientScopes,
  EnvironmentId,
} from "@t3tools/contracts";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { McpProtocol, McpServer } from "effect/ai";
import { HttpBody, HttpClient, HttpRouter } from "effect/http";

import * as EnvironmentAuth from "../auth/EnvironmentAuth.ts";
import * as ComputerUse from "../computerUse/ComputerUse.ts";
import { ComputerUseError } from "../computerUse/protocol.ts";
import * as ServerConfig from "../config.ts";
import * as ServerEnvironment from "../environment/ServerEnvironment.ts";
import * as McpHttpServer from "./McpHttpServer.ts";
import * as McpSessionRegistry from "./McpSessionRegistry.ts";
import * as ComputerRegistration from "./toolkits/computer/registration.ts";

const sessionsByToken = {
  "admin-token": AuthAdministrativeScopes,
  "standard-token": AuthStandardClientScopes,
} as const;

/** Serves `/mcp` like the server does, with a computer service that records who called it. */
const serveMcp = (devUrl: URL | undefined) =>
  Effect.gen(function* () {
    const callers: Array<string> = [];
    const computer = Layer.mock(ComputerUse.ComputerUse)({
      snapshot: (caller) =>
        Effect.sync(() => callers.push(caller)).pipe(
          Effect.andThen(Effect.fail(new ComputerUseError({ code: "app_denied" }))),
        ),
    });
    const auth = Layer.mock(EnvironmentAuth.EnvironmentAuth)({
      authenticateHttpRequest: (request) => {
        const token = request.headers.authorization?.slice("Bearer ".length) ?? "";
        const scopes = sessionsByToken[token as keyof typeof sessionsByToken];
        return scopes
          ? Effect.succeed({
              sessionId: AuthSessionId.make(`session-${token}`),
              subject: "cli",
              method: "bearer-access-token" as const,
              scopes,
            })
          : Effect.fail(new EnvironmentAuth.ServerAuthMissingCredentialError());
      },
    });
    const config = Layer.effect(
      ServerConfig.ServerConfig,
      ServerConfig.ServerConfig.pipe(Effect.map((current) => ({ ...current, devUrl }))),
    ).pipe(
      Layer.provide(ServerConfig.layerTest(process.cwd(), { prefix: "t3-mcp-dev-harness-test-" })),
    );
    const transport = McpServer.layerHttp({
      name: "MCP dev harness test",
      version: "1.0.0",
      path: "/mcp",
      protocols: [McpProtocol.v2025_06_18],
    }).pipe(Layer.provide(McpHttpServer.layerMcpAuthMiddleware));
    yield* HttpRouter.serve(ComputerRegistration.layer.pipe(Layer.provideMerge(transport)), {
      disableListenLog: true,
      disableLogger: true,
    }).pipe(
      Layer.provide(computer),
      Layer.provide(auth),
      Layer.provide(config),
      Layer.provide(
        Layer.mock(McpSessionRegistry.McpSessionRegistry)({ resolve: () => Effect.undefined }),
      ),
      Layer.provide(
        Layer.mock(ServerEnvironment.ServerEnvironment)({
          getEnvironmentId: Effect.succeed(EnvironmentId.make("environment-dev")),
        }),
      ),
      Layer.provide(NodeServices.layer),
      Layer.build,
    );
    return callers;
  });

/** Initializes an MCP session and asks for a Calculator snapshot; returns the HTTP status and body. */
const snapshotCalculator = (headers: Record<string, string>) =>
  Effect.gen(function* () {
    const httpClient = yield* HttpClient.HttpClient;
    const post = (body: string, sessionId?: string) =>
      httpClient.post("/mcp", {
        headers: {
          ...headers,
          accept: "application/json, text/event-stream",
          ...(sessionId
            ? { "mcp-session-id": sessionId, "mcp-protocol-version": "2025-06-18" }
            : {}),
        },
        body: HttpBody.text(body, "application/json"),
      });
    const initialized = yield* post(
      `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"dev-harness-test","version":"1"}}}`,
    );
    if (initialized.status !== 200) return { status: initialized.status, body: "" };
    const called = yield* post(
      `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"computer_snapshot","arguments":{"app":"Calculator"}}}`,
      initialized.headers["mcp-session-id"],
    );
    return { status: called.status, body: yield* called.text };
  });

const devUrl = new URL("http://127.0.0.1:5733/");

it.effect("lets an admin credential on a dev server drive computer use as the dev harness", () =>
  Effect.scoped(
    Effect.gen(function* () {
      const callers = yield* serveMcp(devUrl);
      const result = yield* snapshotCalculator({ authorization: "Bearer admin-token" });
      expect(result.status).toBe(200);
      // The service's own refusal comes back, so the request reached ComputerUse.
      expect(result.body).toContain("This app is not allowed for computer use.");
      expect(callers).toEqual(["environment-dev:dev-harness:dev-harness:session-admin-token"]);
    }),
  ).pipe(Effect.provide(NodeHttpServer.layerTest)),
);

it.effect.each([
  ["a standard credential", devUrl, { authorization: "Bearer standard-token" }],
  ["a non-dev server", undefined, { authorization: "Bearer admin-token" }],
  [
    "a proxied request",
    devUrl,
    { authorization: "Bearer admin-token", "x-forwarded-for": "100.64.0.2" },
  ],
] as const)("refuses %s", ([, url, headers]) =>
  Effect.scoped(
    Effect.gen(function* () {
      const callers = yield* serveMcp(url);
      const result = yield* snapshotCalculator(headers);
      expect(result.status).toBe(401);
      expect(callers).toEqual([]);
    }),
  ).pipe(Effect.provide(NodeHttpServer.layerTest)),
);
