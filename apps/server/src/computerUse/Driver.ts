// @effect-diagnostics nodeBuiltinImport:off globalTimers:off -- Native addon isolation requires a killable child process.
import * as NodeChildProcess from "node:child_process";
import * as HostProcess from "@t3tools/shared/HostProcess";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import * as Semaphore from "effect/Semaphore";
import { ComputerUseError, WorkerResponse, type WorkerRequest } from "./protocol.ts";

export class Driver extends Context.Service<
  Driver,
  {
    readonly execute: (request: WorkerRequest) => Effect.Effect<WorkerResponse, ComputerUseError>;
    readonly withSession: <A, E, R>(
      effect: Effect.Effect<A, E, R>,
    ) => Effect.Effect<A, E | ComputerUseError, R>;
  }
>()("t3/computerUse/Driver") {}

const decodeResponse = Schema.decodeUnknownSync(Schema.fromJsonString(WorkerResponse));
const encodeRequest = Schema.encodeSync(Schema.fromJsonString(Schema.Unknown));
const isComputerUseError = Schema.is(ComputerUseError);
const failure = (stage: "worker_start" | "worker_exit" | "worker_response") =>
  new ComputerUseError({ code: "failed", detail: { stage, reason: "unknown" } });

type Session = { execute: Driver["Service"]["execute"]; close: () => Promise<void> };
const CurrentSession = Context.Reference<Session | undefined>("t3/computerUse/CurrentSession", {
  defaultValue: () => undefined,
});

function start(execPath: string, args: string[], env: NodeJS.ProcessEnv): Session {
  // No prompt or user text enters argv, nor inherited --watch/--inspect flags.
  const child = NodeChildProcess.spawn(execPath, [...args, "--session"], {
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...env, ELECTRON_RUN_AS_NODE: "1" },
  });
  let stopped: ComputerUseError | undefined;
  let output = "";
  let pending:
    | { resolve: (response: WorkerResponse) => void; reject: (error: ComputerUseError) => void }
    | undefined;
  const stop = (error: ComputerUseError) => {
    stopped ??= error;
    child.kill("SIGKILL");
    pending?.reject(stopped);
  };
  const closed = new Promise<void>((resolve) =>
    child.once("close", () => {
      stop(failure("worker_exit"));
      resolve();
    }),
  );
  // A batch owns the process; even a forgotten caller cannot keep it indefinitely.
  const lifetime = setTimeout(() => stop(failure("worker_exit")), 300_000);
  lifetime.unref();
  void closed.then(() => clearTimeout(lifetime));
  child.on("error", () => stop(failure("worker_start")));
  child.stdin.on("error", () => stop(failure("worker_exit")));
  // Native error messages can contain app text; never relay or log stderr.
  child.stderr.resume();
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk: string) => {
    output += chunk;
    if (Buffer.byteLength(output) > 12 * 1024 * 1024) return stop(failure("worker_response"));
    const newline = output.indexOf("\n");
    if (newline === -1) return;
    if (!pending || newline !== output.length - 1) return stop(failure("worker_response"));
    try {
      const response = decodeResponse(output.slice(0, newline));
      output = "";
      pending.resolve(response);
    } catch {
      stop(failure("worker_response"));
    }
  });
  const mutex = Semaphore.makeUnsafe(1);
  return {
    execute: (request) =>
      mutex.withPermits(1)(
        Effect.tryPromise({
          try: (signal) =>
            new Promise<WorkerResponse>((resolve, reject) => {
              if (stopped) return reject(stopped);
              const raw = encodeRequest(request);
              if (Buffer.byteLength(raw) > 65_536) return reject(failure("worker_start"));
              const abort = () => stop(failure("worker_exit"));
              const timer = setTimeout(abort, request.kind === "open" ? 25_000 : 12_000);
              const finish = () => {
                clearTimeout(timer);
                signal.removeEventListener("abort", abort);
                pending = undefined;
              };
              pending = {
                resolve: (response) => {
                  finish();
                  resolve(response);
                },
                reject: (error) => {
                  finish();
                  reject(error);
                },
              };
              signal.addEventListener("abort", abort, { once: true });
              if (signal.aborted) return abort();
              child.stdin.write(`${raw}\n`);
            }),
          catch: (cause) => (isComputerUseError(cause) ? cause : failure("worker_start")),
        }),
      ),
    close: () => {
      stop(failure("worker_exit"));
      return closed;
    },
  };
}

const make = Effect.gen(function* () {
  const argv = yield* HostProcess.Arguments;
  const execPath = yield* HostProcess.ExecutablePath;
  const env = yield* HostProcess.Environment;
  const isExecutable = yield* HostProcess.IsExecutable;
  const session = Effect.acquireRelease(
    Effect.try({
      try: () => {
        if (!isExecutable && !argv[1]) throw failure("worker_start");
        return start(
          execPath,
          isExecutable ? ["__computer-use"] : [argv[1]!, "__computer-use"],
          env,
        );
      },
      catch: () => failure("worker_start"),
    }),
    (worker) => Effect.promise(() => worker.close()),
  );
  const withSession: Driver["Service"]["withSession"] = (effect) =>
    Effect.scoped(
      Effect.flatMap(session, (worker) => Effect.provideService(effect, CurrentSession, worker)),
    );
  const execute = Effect.fn("ComputerUse.Driver.execute")(function* (request: WorkerRequest) {
    const worker = yield* CurrentSession;
    if (worker) return yield* worker.execute(request);
    return yield* Effect.scoped(Effect.flatMap(session, (single) => single.execute(request)));
  });
  return Driver.of({ execute, withSession });
});
export const layer = Layer.effect(Driver, make);
