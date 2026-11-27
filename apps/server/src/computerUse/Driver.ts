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

type Session = {
  execute: Driver["Service"]["execute"];
  close: () => Promise<void>;
  /** Hands the process to one batch and starts that batch's lifetime limit. */
  claim: () => void;
  readonly alive: () => boolean;
};
const CurrentSession = Context.Reference<Session | undefined>("t3/computerUse/CurrentSession", {
  defaultValue: () => undefined,
});

/** How long a started worker waits for a call before it exits. */
const SPARE_IDLE_MS = 120_000;
/**
 * Reads one worker answers before it is replaced. The worker ends its session after 64
 * requests, and its native calls leave CF objects for the process exit to free.
 */
const READER_REQUESTS = 48;
const READER_AGE_MS = 300_000;

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
  let lifetime: ReturnType<typeof setTimeout> | undefined;
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
    claim: () => {
      if (lifetime) return;
      // A batch owns the process; even a forgotten caller cannot keep it indefinitely.
      lifetime = setTimeout(() => stop(failure("worker_exit")), 300_000);
      lifetime.unref();
    },
    alive: () => stopped === undefined && child.exitCode === null && child.signalCode === null,
  };
}

const make = Effect.gen(function* () {
  const argv = yield* HostProcess.Arguments;
  const execPath = yield* HostProcess.ExecutablePath;
  const env = yield* HostProcess.Environment;
  const isExecutable = yield* HostProcess.IsExecutable;
  const spawn = () => {
    if (!isExecutable && !argv[1]) throw failure("worker_start");
    return start(execPath, isExecutable ? ["__computer-use"] : [argv[1]!, "__computer-use"], env);
  };
  // Starting a worker and loading its native libraries takes longer than most
  // calls, so each batch still gets a fresh process, started before it asked.
  let spare: { readonly worker: Session; readonly idle: ReturnType<typeof setTimeout> } | undefined;
  const takeSpare = () => {
    const ready = spare;
    spare = undefined;
    if (!ready) return undefined;
    clearTimeout(ready.idle);
    if (ready.worker.alive()) return ready.worker;
    void ready.worker.close();
    return undefined;
  };
  const refill = () => {
    if (spare) return;
    try {
      const worker = spawn();
      const idle = setTimeout(() => {
        if (spare?.worker === worker) spare = undefined;
        void worker.close();
      }, SPARE_IDLE_MS);
      idle.unref();
      spare = { worker, idle };
    } catch {
      // The next batch starts its own worker and reports the failure.
    }
  };
  // Snapshots change nothing and never arm the focus guard, so consecutive ones share a
  // worker until it has answered READER_REQUESTS, gets old, fails or sits idle. A snapshot
  // that arrives while another is running gets its own worker rather than waiting behind it.
  // Every action batch, and every permission check, still gets a fresh process.
  type Timer = ReturnType<typeof setTimeout>;
  type Reader = {
    readonly worker: Session;
    served: number;
    stale: boolean;
    busy: boolean;
    idle?: Timer;
  };
  let reader: Reader | undefined;
  const retire = (current: Reader | undefined) => {
    if (!current || reader !== current) return;
    reader = undefined;
    clearTimeout(current.idle);
    void current.worker.close();
  };
  const idleUntilRetired = (current: Reader) => {
    clearTimeout(current.idle);
    if (reader !== current) return;
    current.idle = setTimeout(() => retire(current), SPARE_IDLE_MS);
    current.idle.unref();
  };
  const readerFor = (): Reader | undefined => {
    if (reader?.busy) return undefined;
    if (reader && reader.worker.alive() && !reader.stale && reader.served < READER_REQUESTS) {
      clearTimeout(reader.idle);
      return reader;
    }
    retire(reader);
    const current: Reader = {
      worker: takeSpare() ?? spawn(),
      served: 0,
      stale: false,
      busy: false,
    };
    refill();
    setTimeout(() => {
      current.stale = true;
    }, READER_AGE_MS).unref();
    reader = current;
    return current;
  };
  const once = (request: WorkerRequest) =>
    Effect.scoped(Effect.flatMap(session, (single) => single.execute(request)));
  const read = (request: WorkerRequest) =>
    Effect.suspend(() => {
      let current: Reader | undefined;
      try {
        current = readerFor();
      } catch {
        return Effect.fail(failure("worker_start"));
      }
      if (!current) return once(request);
      const used = current;
      used.served++;
      used.busy = true;
      return used.worker.execute(request).pipe(
        // macOS decides Screen Recording for a process when it starts.
        Effect.tap((response) =>
          Effect.sync(() => {
            if (!response.ok && response.code === "permissions") retire(used);
          }),
        ),
        Effect.tapError(() => Effect.sync(() => retire(used))),
        Effect.ensuring(
          Effect.sync(() => {
            used.busy = false;
            idleUntilRetired(used);
          }),
        ),
      );
    });
  yield* Effect.addFinalizer(() =>
    Effect.promise(async () => {
      const current = reader;
      retire(current);
      await Promise.all([takeSpare()?.close(), current?.worker.close()]);
    }),
  );
  const session = Effect.acquireRelease(
    Effect.try({
      try: () => {
        const worker = takeSpare() ?? spawn();
        worker.claim();
        refill();
        return worker;
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
    if (request.kind === "snapshot") return yield* read(request);
    return yield* once(request);
  });
  return Driver.of({ execute, withSession });
});
export const layer = Layer.effect(Driver, make);
