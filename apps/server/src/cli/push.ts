import * as Console from "effect/Console";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as References from "effect/References";
import * as Schema from "effect/Schema";
import { Command, Flag, GlobalFlag } from "effect/cli";

import * as ServerSecretStore from "../auth/ServerSecretStore.ts";
import * as ServerConfig from "../config.ts";
import * as Apns from "../push/apns.ts";
import {
  DIRECT_PUSH_APNS_CREDENTIALS_SECRET,
  encodeStoredApnsCredentials,
  readApnsCredentials,
  readDirectPushDevices,
} from "../push/DirectPush.ts";
import { authLocationFlags, type CliAuthLocationFlags, resolveCliAuthConfig } from "./config.ts";

export class DirectPushKeyError extends Schema.TaggedError<DirectPushKeyError>()(
  "DirectPushKeyError",
  { detail: Schema.String },
) {
  override get message(): string {
    return this.detail;
  }
}

/** The key and devices live in this environment's secret store, so these work with the server stopped. */
const runWithPushStore = Effect.fn("push.runWithPushStore")(function* <A, E, R>(
  flags: CliAuthLocationFlags,
  run: (
    secrets: ServerSecretStore.ServerSecretStore["Service"],
  ) => Effect.Effect<A, E, R | Apns.ApnsSender>,
) {
  const logLevel = yield* GlobalFlag.LogLevel;
  const config = yield* resolveCliAuthConfig(flags, logLevel, { quietLogs: true });
  return yield* Effect.gen(function* () {
    return yield* run(yield* ServerSecretStore.ServerSecretStore);
  }).pipe(
    Effect.provide(
      Layer.mergeAll(ServerSecretStore.layer, Apns.layer).pipe(
        Layer.provide(ServerConfig.layer(config)),
        Layer.provide(Layer.succeed(References.MinimumLogLevel, "Error")),
      ),
    ),
  );
});

const APPLE_ID_PATTERN = /^[A-Z0-9]{10}$/;

const pushKeyCommand = Command.make("key", {
  ...authLocationFlags,
  teamId: Flag.String("team-id").pipe(
    Flag.withDescription("Your Apple Developer team ID (10 characters)."),
    Flag.optional,
  ),
  keyId: Flag.String("key-id").pipe(
    Flag.withDescription("The APNs key's ID (10 characters, also in its AuthKey_<id>.p8 name)."),
    Flag.optional,
  ),
  keyFile: Flag.String("key-file").pipe(
    Flag.withDescription("Path to the AuthKey_<id>.p8 file downloaded from Apple."),
    Flag.optional,
  ),
  remove: Flag.Boolean("remove").pipe(
    Flag.withDescription("Forget the stored APNs key."),
    Flag.withDefault(false),
  ),
}).pipe(
  Command.withDescription(
    "Store an APNs key so this environment can send notifications directly to apps signed by your Apple team.",
  ),
  Command.withHandler((flags) =>
    runWithPushStore(flags, (secrets) =>
      Effect.gen(function* () {
        if (flags.remove) {
          yield* secrets.remove(DIRECT_PUSH_APNS_CREDENTIALS_SECRET);
          yield* Console.log("Removed the APNs key. Direct push notifications are off.");
          return;
        }
        if (
          Option.isNone(flags.teamId) ||
          Option.isNone(flags.keyId) ||
          Option.isNone(flags.keyFile)
        ) {
          return yield* new DirectPushKeyError({
            detail: "Pass --team-id, --key-id and --key-file together, or --remove.",
          });
        }
        const keyFile = flags.keyFile.value;
        const teamId = flags.teamId.value.trim().toUpperCase();
        const keyId = flags.keyId.value.trim().toUpperCase();
        if (!APPLE_ID_PATTERN.test(teamId) || !APPLE_ID_PATTERN.test(keyId)) {
          return yield* new DirectPushKeyError({
            detail:
              "Team and key IDs are 10 letters or digits, as shown in the Apple Developer portal.",
          });
        }
        const fs = yield* FileSystem.FileSystem;
        const privateKey = yield* fs.readFileString(keyFile).pipe(
          Effect.mapError(
            (cause) =>
              new DirectPushKeyError({
                detail: `Could not read ${keyFile}: ${cause.message}`,
              }),
          ),
        );
        yield* Effect.try({
          try: () => Apns.makeApnsProviderToken({ teamId, keyId, privateKey }, 0),
          catch: () =>
            new DirectPushKeyError({
              detail: `${keyFile} is not an APNs key. Download the .p8 file from Certificates, Identifiers & Profiles > Keys.`,
            }),
        });
        yield* secrets.set(
          DIRECT_PUSH_APNS_CREDENTIALS_SECRET,
          new TextEncoder().encode(encodeStoredApnsCredentials({ teamId, keyId, privateKey })),
        );
        yield* Console.log(
          `Stored APNs key ${keyId} for team ${teamId}. Run \`t3 push test\` once your phone has registered.`,
        );
      }),
    ),
  ),
);

const pushStatusCommand = Command.make("status", { ...authLocationFlags }).pipe(
  Command.withDescription("Show the APNs key and the devices registered for direct push."),
  Command.withHandler((flags) =>
    runWithPushStore(flags, (secrets) =>
      Effect.gen(function* () {
        const credentials = yield* readApnsCredentials(secrets);
        const devices = yield* readDirectPushDevices(secrets);
        yield* Console.log(
          credentials === null
            ? "APNs key: not set. Run `t3 push key`."
            : `APNs key: ${credentials.keyId} (team ${credentials.teamId})`,
        );
        if (devices.length === 0) {
          yield* Console.log(
            "Devices: none. Open the app on a phone paired with this environment.",
          );
          return;
        }
        yield* Console.log(`Devices (${String(devices.length)}):`);
        for (const device of devices) {
          // Direct push sends alerts only, so the Live Activity switch is not reported.
          const off = Object.entries(device.preferences)
            .filter(([name, enabled]) => !enabled && name !== "liveActivitiesEnabled")
            .map(([name]) => name);
          yield* Console.log(
            `  ${device.label}  ${device.bundleId} (${device.apsEnvironment})  token …${device.pushToken.slice(-8)}  registered ${device.registeredAt}${off.length > 0 ? `  off: ${off.join(", ")}` : ""}`,
          );
        }
      }),
    ),
  ),
);

const pushTestCommand = Command.make("test", { ...authLocationFlags }).pipe(
  Command.withDescription("Send a test notification to every device registered for direct push."),
  Command.withHandler((flags) =>
    runWithPushStore(flags, (secrets) =>
      Effect.gen(function* () {
        const credentials = yield* readApnsCredentials(secrets);
        if (credentials === null) {
          return yield* new DirectPushKeyError({ detail: "No APNs key. Run `t3 push key` first." });
        }
        const devices = yield* readDirectPushDevices(secrets);
        if (devices.length === 0) {
          yield* Console.log(
            "No devices registered. Open the app on a phone paired with this environment.",
          );
          return;
        }
        const apns = yield* Apns.ApnsSender;
        for (const device of devices) {
          const response = yield* apns
            .sendAlert(credentials, {
              token: device.pushToken,
              topic: device.bundleId,
              environment: device.apsEnvironment,
              alert: {
                title: "T3 Code",
                body: "Direct push works on this device.",
                environmentId: "",
                threadId: "",
                deepLink: "/",
              },
            })
            .pipe(Effect.result);
          yield* Console.log(
            response._tag === "Failure"
              ? `✗ ${device.label}: ${response.failure.message}`
              : response.success.status >= 200 && response.success.status < 300
                ? `✓ ${device.label}`
                : `✗ ${device.label}: APNs ${String(response.success.status)} ${response.success.reason ?? ""}`.trimEnd(),
          );
        }
      }),
    ),
  ),
);

export const pushCommand = Command.make("push").pipe(
  Command.withDescription(
    "Send agent notifications straight to your own signed iOS build with your APNs key, without T3 Connect.",
  ),
  Command.withSubcommands([pushKeyCommand, pushStatusCommand, pushTestCommand]),
);
