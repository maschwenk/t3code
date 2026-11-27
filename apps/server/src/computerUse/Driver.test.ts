// @effect-diagnostics nodeBuiltinImport:off -- Exercise the real isolated worker transport.
import * as NodeFSP from "node:fs/promises";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import { expect, it } from "@effect/vitest";
import * as HostProcess from "@t3tools/shared/HostProcess";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Layer from "effect/Layer";
import * as Result from "effect/Result";
import * as Driver from "./Driver.ts";
import type { WorkerRequest } from "./protocol.ts";

const request = (app = "fixture"): WorkerRequest => ({
  kind: "snapshot",
  app,
  includeImage: false,
  options: { offset: 0, limit: 1, includeOffscreen: false },
});
const fixtureFiles = Effect.gen(function* () {
  const dir = yield* Effect.acquireRelease(
    Effect.promise(() => NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "t3-worker-"))),
    (path) => Effect.promise(() => NodeFSP.rm(path, { recursive: true, force: true })),
  );
  const path = NodePath.join(dir, "worker.cjs");
  const started = NodePath.join(dir, "started.log");
  yield* Effect.promise(() =>
    NodeFSP.writeFile(
      path,
      `
    require('node:fs').appendFileSync(${JSON.stringify(started)}, process.pid + '\\n');
    const lines = require('node:readline').createInterface({ input: process.stdin });
    lines.on('line', line => {
      const request = JSON.parse(line);
      if (request.app === 'crash') process.exit(1);
      if (request.app === 'malformed') { process.stdout.write('private-native-error\\n'); return; }
      process.stdout.write(JSON.stringify({ ok: true, inputAt: process.pid }) + '\\n');
    });
  `,
    ),
  );
  const layer = Driver.layer.pipe(
    Layer.provide(Layer.succeed(HostProcess.Arguments, [process.execPath, path])),
  );
  const startedPids = () =>
    NodeFSP.readFile(started, "utf8")
      .catch(() => "")
      .then((text) => text.split("\n").filter(Boolean).map(Number));
  return { layer, startedPids };
});
const fixture = Effect.map(fixtureFiles, ({ layer }) => layer);
const running = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

it.live("answers the next batch from a worker started before it asked", () =>
  Effect.gen(function* () {
    const { layer, startedPids } = yield* fixtureFiles;
    yield* Effect.gen(function* () {
      const driver = yield* Driver.Driver;
      const batch = driver.withSession(driver.execute(request()));
      const first = yield* batch;
      // The spare starts as soon as the first batch takes its worker.
      yield* Effect.promise(() => expect.poll(startedPids).toHaveLength(2));
      const before = yield* Effect.promise(startedPids);
      const second = yield* batch;
      if (!first.ok || !second.ok || !second.inputAt) throw new Error("Missing worker pid");
      expect(second.inputAt).not.toBe(first.inputAt);
      expect(before).toContain(second.inputAt);
    }).pipe(Effect.provide(layer));
    // Closing the service leaves no worker behind, spare included.
    yield* Effect.promise(() =>
      expect.poll(async () => (await startedPids()).filter(running)).toEqual([]),
    );
  }).pipe(Effect.scoped),
);

it.live("answers consecutive reads from one worker and replaces it after a failure", () =>
  Effect.gen(function* () {
    const { layer, startedPids } = yield* fixtureFiles;
    yield* Effect.gen(function* () {
      const driver = yield* Driver.Driver;
      const pid = (response: { ok: boolean; inputAt?: number }) => response.inputAt;
      const reads = yield* Effect.forEach([1, 2, 3], () => driver.execute(request()));
      expect(new Set(reads.map(pid)).size).toBe(1);
      // An action batch never runs in the shared reader.
      const batch = yield* driver.withSession(driver.execute(request()));
      expect(pid(batch)).not.toBe(pid(reads[0]!));
      expect(pid(yield* driver.execute(request()))).toBe(pid(reads[0]!));
      // A permission check runs in a fresh process, which sees grants made since.
      const permissions = yield* driver.execute({ kind: "permissions" });
      expect(pid(permissions)).not.toBe(pid(reads[0]!));
      // A read that overlaps another gets its own worker and leaves the shared one alone.
      const [one, two] = yield* Effect.all([driver.execute(request()), driver.execute(request())], {
        concurrency: "unbounded",
      });
      expect(new Set([pid(one), pid(two)]).size).toBe(2);
      expect([pid(one), pid(two)]).toContain(pid(reads[0]!));
      expect(pid(yield* driver.execute(request()))).toBe(pid(reads[0]!));
      expect(Result.isFailure(yield* Effect.result(driver.execute(request("crash"))))).toBe(true);
      const after = yield* driver.execute(request());
      expect(pid(after)).not.toBe(pid(reads[0]!));
    }).pipe(Effect.provide(layer));
    yield* Effect.promise(() =>
      expect.poll(async () => (await startedPids()).filter(running)).toEqual([]),
    );
  }).pipe(Effect.scoped),
);

it.live("uses one process for a batch and reaps it before returning", () =>
  Effect.gen(function* () {
    const layer = yield* fixture;
    yield* Effect.gen(function* () {
      const driver = yield* Driver.Driver;
      const pids = yield* driver.withSession(
        Effect.forEach([1, 2, 3], () => driver.execute(request())),
      );
      expect(new Set(pids.map((response) => response.ok && response.inputAt)).size).toBe(1);
      const first = pids[0]!;
      if (!first.ok || !first.inputAt) throw new Error("Missing worker pid");
      expect(() => process.kill(first.inputAt!, 0)).toThrow();
      const next = yield* driver.execute(request());
      expect(next.ok && next.inputAt).not.toBe(first.inputAt);
    }).pipe(Effect.provide(layer));
  }).pipe(Effect.scoped),
);

it.live.each(["crash", "malformed"])("does not replay or restart after a %s", (app) =>
  Effect.gen(function* () {
    const layer = yield* fixture;
    yield* Effect.gen(function* () {
      const driver = yield* Driver.Driver;
      yield* driver.withSession(
        Effect.gen(function* () {
          expect((yield* driver.execute(request())).ok).toBe(true);
          const failed = yield* Effect.result(driver.execute(request(app)));
          const later = yield* Effect.result(driver.execute(request()));
          expect(Result.isFailure(failed)).toBe(true);
          expect(Result.isFailure(later)).toBe(true);
          expect(JSON.stringify(failed)).not.toContain("private-native-error");
        }),
      );
    }).pipe(Effect.provide(layer));
  }).pipe(Effect.scoped),
);

it.live("reaps a batch worker when its caller is interrupted", () =>
  Effect.gen(function* () {
    const layer = yield* fixture;
    yield* Effect.gen(function* () {
      const driver = yield* Driver.Driver;
      const ready = yield* Deferred.make<number>();
      const fiber = yield* driver
        .withSession(
          Effect.gen(function* () {
            const response = yield* driver.execute(request());
            if (!response.ok || !response.inputAt) throw new Error("Missing worker pid");
            yield* Deferred.succeed(ready, response.inputAt);
            return yield* Effect.never;
          }),
        )
        .pipe(Effect.forkChild);
      const pid = yield* Deferred.await(ready);
      yield* Fiber.interrupt(fiber);
      expect(() => process.kill(pid, 0)).toThrow();
    }).pipe(Effect.provide(layer));
  }).pipe(Effect.scoped),
);
