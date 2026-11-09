import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Option from "effect/Option";
import * as Ref from "effect/Ref";
import * as Schedule from "effect/Schedule";

import * as DesktopObservability from "../app/DesktopObservability.ts";
import type { DesktopBackendInstance } from "./DesktopBackendManager.ts";

// Reading a ~2 KB entry file this often is negligible, and two agreeing reads
// (about 600 ms) are enough to know the rebuild finished writing.
const POLL_INTERVAL = Duration.millis(300);

const { logInfo } = DesktopObservability.makeComponentLogger("desktop-dev-server-reload");

const sameBytes = (left: Uint8Array, right: Uint8Array) =>
  left.length === right.length && left.every((byte, index) => byte === right[index]);

/**
 * Development only. Restarts just the backend child once scripts/dev-electron.mjs's
 * watch rebuild changes the bundle entry and it holds still for one poll, instead of
 * relaunching Electron. Identical rebuilds, such as the watcher's first, are ignored.
 */
export const restartBackendOnServerRebuild = Effect.fn("desktop.dev.restartBackendOnServerRebuild")(
  function* (backend: DesktopBackendInstance, entryPath: string) {
    const fileSystem = yield* FileSystem.FileSystem;
    const readEntry = fileSystem.readFile(entryPath).pipe(Effect.option);
    const running = yield* Ref.make(yield* readEntry);
    const previous = yield* Ref.make(yield* Ref.get(running));

    const poll = Effect.gen(function* () {
      const next = yield* readEntry;
      const last = yield* Ref.getAndSet(previous, next);
      // Mid-rebuild, or still being written: wait until two polls agree.
      if (Option.isNone(next) || Option.isNone(last) || !sameBytes(next.value, last.value)) return;
      const current = yield* Ref.get(running);
      if (Option.isSome(current) && sameBytes(current.value, next.value)) return;
      yield* Ref.set(running, next);
      yield* logInfo("server bundle changed; restarting backend", { entryPath });
      yield* backend.stop();
      yield* backend.start;
    });

    yield* poll.pipe(Effect.repeat(Schedule.spaced(POLL_INTERVAL)));
  },
);
