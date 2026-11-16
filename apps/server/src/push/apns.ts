// @effect-diagnostics nodeBuiltinImport:off -- APNs only speaks HTTP/2, and outbound fetch here stays on HTTP/1.1; Effect's crypto has no ES256 signing.
import * as NodeCrypto from "node:crypto";
import * as NodeHttp2 from "node:http2";

import * as Clock from "effect/Clock";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";

export type ApnsEnvironment = "sandbox" | "production";

export interface ApnsCredentials {
  readonly teamId: string;
  readonly keyId: string;
  /** PKCS#8 PEM, the contents of the AuthKey_<keyId>.p8 file. */
  readonly privateKey: string;
}

export interface ApnsAlert {
  readonly title: string;
  readonly body: string;
  readonly environmentId: string;
  readonly threadId: string;
  readonly deepLink: string;
}

export interface ApnsAlertRequest {
  readonly token: string;
  /** The app's bundle identifier. */
  readonly topic: string;
  readonly environment: ApnsEnvironment;
  readonly alert: ApnsAlert;
}

export interface ApnsResponse {
  readonly status: number;
  readonly reason: string | null;
}

export class ApnsRequestError extends Schema.TaggedError<ApnsRequestError>()("ApnsRequestError", {
  topic: Schema.String,
  environment: Schema.Literals(["sandbox", "production"]),
  tokenSuffix: Schema.String,
  cause: Schema.Defect(),
}) {
  override get message(): string {
    return `APNs request to ${this.environment} for ${this.topic} failed.`;
  }
}

// Apple rejects tokens older than an hour and throttles refreshes more often than every 20 minutes.
const PROVIDER_TOKEN_REUSE_SECONDS = 45 * 60;
const REQUEST_TIMEOUT_MS = 10_000;

export function makeApnsProviderToken(
  credentials: ApnsCredentials,
  issuedAtUnixSeconds: number,
): string {
  const header = Buffer.from(JSON.stringify({ alg: "ES256", kid: credentials.keyId })).toString(
    "base64url",
  );
  const payload = Buffer.from(
    JSON.stringify({ iss: credentials.teamId, iat: issuedAtUnixSeconds }),
  ).toString("base64url");
  const signingInput = `${header}.${payload}`;
  const signature = NodeCrypto.sign("sha256", Buffer.from(signingInput), {
    key: credentials.privateKey,
    dsaEncoding: "ieee-p1363",
  });
  return `${signingInput}.${signature.toString("base64url")}`;
}

/** Same shape as the relay's alerts, so the app's tap handling opens the thread either way. */
export function makeApnsAlertPayload(alert: ApnsAlert) {
  return {
    aps: {
      alert: { title: alert.title, body: alert.body },
      sound: "default",
      "thread-id":
        alert.threadId.length > 0 ? `${alert.environmentId}/${alert.threadId}` : "t3-agent-alerts",
    },
    // Expo iOS exposes userInfo.body as notification.content.data for remote pushes.
    body: {
      environmentId: alert.environmentId,
      threadId: alert.threadId,
      deepLink: alert.deepLink,
    },
  };
}

function reasonFromBody(body: string): string | null {
  if (body.trim().length === 0) return null;
  try {
    const parsed: unknown = JSON.parse(body);
    if (typeof parsed === "object" && parsed !== null && "reason" in parsed) {
      return typeof parsed.reason === "string" ? parsed.reason : body;
    }
  } catch {
    // Fall through to the raw body.
  }
  return body;
}

// Alerts are a few per hour, so each send opens and closes its own connection instead of keeping one alive.
function postOverHttp2(input: {
  readonly origin: string;
  readonly path: string;
  readonly headers: Record<string, string>;
  readonly payload: unknown;
}): Promise<ApnsResponse> {
  return new Promise((resolve, reject) => {
    const session = NodeHttp2.connect(input.origin);
    const fail = (error: unknown) => {
      session.destroy();
      reject(error);
    };
    session.on("error", fail);
    const request = session.request({
      ":method": "POST",
      ":path": input.path,
      "content-type": "application/json",
      ...input.headers,
    });
    let status = 0;
    let responseBody = "";
    request.setEncoding("utf8");
    request.setTimeout(REQUEST_TIMEOUT_MS, () => {
      request.close(NodeHttp2.constants.NGHTTP2_CANCEL);
      fail(new Error("APNs request timed out"));
    });
    request.on("response", (headers) => {
      status = Number(headers[":status"]);
    });
    request.on("data", (chunk: string) => {
      responseBody += chunk;
    });
    request.on("end", () => {
      session.close();
      resolve({ status, reason: reasonFromBody(responseBody) });
    });
    request.on("error", fail);
    request.end(JSON.stringify(input.payload));
  });
}

export class ApnsSender extends Context.Service<
  ApnsSender,
  {
    readonly sendAlert: (
      credentials: ApnsCredentials,
      request: ApnsAlertRequest,
    ) => Effect.Effect<ApnsResponse, ApnsRequestError>;
  }
>()("t3/push/apns/ApnsSender") {}

const make = Effect.sync(() => {
  let cachedProviderToken: {
    readonly key: string;
    readonly jwt: string;
    readonly issuedAt: number;
  } | null = null;
  const providerToken = (credentials: ApnsCredentials, nowSeconds: number) => {
    const key = `${credentials.teamId}:${credentials.keyId}:${credentials.privateKey}`;
    if (
      cachedProviderToken?.key === key &&
      nowSeconds - cachedProviderToken.issuedAt < PROVIDER_TOKEN_REUSE_SECONDS
    ) {
      return cachedProviderToken.jwt;
    }
    const jwt = makeApnsProviderToken(credentials, nowSeconds);
    cachedProviderToken = { key, jwt, issuedAt: nowSeconds };
    return jwt;
  };

  return ApnsSender.of({
    sendAlert: Effect.fn("ApnsSender.sendAlert")(function* (credentials, request) {
      const nowSeconds = Math.floor((yield* Clock.currentTimeMillis) / 1_000);
      return yield* Effect.tryPromise({
        try: () =>
          postOverHttp2({
            origin:
              request.environment === "production"
                ? "https://api.push.apple.com"
                : "https://api.sandbox.push.apple.com",
            path: `/3/device/${request.token}`,
            headers: {
              authorization: `bearer ${providerToken(credentials, nowSeconds)}`,
              "apns-push-type": "alert",
              "apns-priority": "10",
              "apns-topic": request.topic,
            },
            payload: makeApnsAlertPayload(request.alert),
          }),
        catch: (cause) =>
          new ApnsRequestError({
            topic: request.topic,
            environment: request.environment,
            tokenSuffix: request.token.slice(-8),
            cause,
          }),
      });
    }),
  });
});

export const layer = Layer.effect(ApnsSender, make);
