// @effect-diagnostics nodeBuiltinImport:off -- Native addon isolation requires a killable child process.
import * as NodeChildProcess from "node:child_process";
import {
  HostProcessArguments,
  HostProcessExecutablePath,
  HostProcessEnvironment,
  HostProcessIsExecutable,
} from "@t3tools/shared/hostProcess";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import { ComputerUseError, WorkerResponse, type WorkerRequest } from "./protocol.ts";

export class Driver extends Context.Service<
  Driver,
  {
    readonly execute: (request: WorkerRequest) => Effect.Effect<WorkerResponse, ComputerUseError>;
  }
>()("t3/computerUse/Driver") {}

const decodeResponse = Schema.decodeUnknownSync(Schema.fromJsonString(WorkerResponse));
const encodeRequest = Schema.encodeSync(Schema.fromJsonString(Schema.Unknown));

const make = Effect.gen(function* () {
  const argv = yield* HostProcessArguments;
  const execPath = yield* HostProcessExecutablePath;
  const env = yield* HostProcessEnvironment;
  const isExecutable = yield* HostProcessIsExecutable;
  return Driver.of({
    execute: (request) =>
      Effect.tryPromise({
        try: (signal) =>
          new Promise<WorkerResponse>((resolve, reject) => {
            // Works in source, npm bundles, and the single executable. No prompt or
            // user text is passed in argv, and no inherited --watch/--inspect flags.
            if (!isExecutable && !argv[1]) {
              reject(new Error("Missing server entrypoint"));
              return;
            }
            const args = isExecutable ? ["__computer-use"] : [argv[1]!, "__computer-use"];
            const child = NodeChildProcess.spawn(execPath, args, {
              stdio: ["pipe", "pipe", "pipe"],
              signal,
              timeout: 12_000,
              killSignal: "SIGKILL",
              env: { ...env, ELECTRON_RUN_AS_NODE: "1" },
            });
            let output = "";
            child.stdout.setEncoding("utf8");
            child.stdout.on("data", (chunk: string) => {
              output += chunk;
              if (output.length > 12 * 1024 * 1024) {
                child.kill("SIGKILL");
                reject(new Error("Output too large"));
              }
            });
            // Native error messages can contain app text; never relay or log stderr.
            child.stderr.resume();
            child.stdin.on("error", reject);
            child.on("error", reject);
            child.on("close", (code) => {
              if (code !== 0) {
                reject(new Error("Computer-use worker failed"));
                return;
              }
              try {
                resolve(decodeResponse(output));
              } catch {
                reject(new Error("Invalid computer-use worker response"));
              }
            });
            child.stdin.end(encodeRequest(request));
          }),
        catch: (cause) => new ComputerUseError({ code: "failed", cause }),
      }),
  });
});
export const layer = Layer.effect(Driver, make);
