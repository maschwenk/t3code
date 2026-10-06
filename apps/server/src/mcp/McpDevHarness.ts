import {
  AuthAccessWriteScope,
  ProviderInstanceId,
  ThreadId,
  type EnvironmentId,
} from "@t3tools/contracts";
import * as Clock from "effect/Clock";
import * as Effect from "effect/Effect";
import { HttpServerRequest } from "effect/http";

import * as EnvironmentAuth from "../auth/EnvironmentAuth.ts";
import { deriveAuthClientMetadata } from "../auth/utils.ts";
import * as ServerConfig from "../config.ts";
import * as ServerEnvironment from "../environment/ServerEnvironment.ts";
import type * as McpInvocationContext from "./McpInvocationContext.ts";

/** The provider instance id the harness acts as; the agent cursor labels it "Dev harness". */
export const DEV_HARNESS_ID = "dev-harness";

const LOOPBACK_ADDRESSES = new Set(["127.0.0.1", "::1"]);
const FORWARDING_HEADERS = ["forwarded", "x-forwarded-for", "x-real-ip"];

const devHarnessScope = (
  environmentId: EnvironmentId,
  sessionId: string,
  issuedAt: number,
): McpInvocationContext.McpThreadInvocationScope => ({
  environmentId,
  requestNamespace: `${DEV_HARNESS_ID}:${sessionId}`,
  thread: {
    threadId: ThreadId.make(DEV_HARNESS_ID),
    providerSessionId: sessionId,
    providerInstanceId: ProviderInstanceId.make(DEV_HARNESS_ID),
  },
  client: undefined,
  // Computer use is reached through the orchestration capability.
  capabilities: new Set(["orchestration"]),
  issuedAt,
});

/**
 * Development servers only: lets `scripts/computer-use-dev.ts` on the same
 * machine call `/mcp` with an administrative environment bearer token, so an
 * agent outside the app can drive computer use through the backend that holds
 * the macOS Accessibility and Screen Recording grants. The request must come
 * straight from loopback; a proxy such as `tailscale serve` adds forwarding
 * headers and is refused. Each environment session is its own caller, so its
 * snapshot receipts carry over between commands.
 */
export const makeResolve = Effect.gen(function* () {
  const config = yield* ServerConfig.ServerConfig;
  if (config.devUrl === undefined) {
    return (_request: HttpServerRequest.HttpServerRequest) =>
      Effect.succeed<McpInvocationContext.McpThreadInvocationScope | undefined>(undefined);
  }
  const auth = yield* EnvironmentAuth.EnvironmentAuth;
  const environmentId = yield* (yield* ServerEnvironment.ServerEnvironment).getEnvironmentId;
  return Effect.fn("McpDevHarness.resolve")(function* (
    request: HttpServerRequest.HttpServerRequest,
  ) {
    const address = deriveAuthClientMetadata({ request }).ipAddress;
    if (
      address === undefined ||
      !LOOPBACK_ADDRESSES.has(address) ||
      FORWARDING_HEADERS.some((header) => request.headers[header] !== undefined)
    ) {
      return undefined;
    }
    const session = yield* auth
      .authenticateHttpRequest(request)
      .pipe(Effect.orElseSucceed(() => undefined));
    if (!session?.scopes.includes(AuthAccessWriteScope)) return undefined;
    return devHarnessScope(environmentId, session.sessionId, yield* Clock.currentTimeMillis);
  });
});
