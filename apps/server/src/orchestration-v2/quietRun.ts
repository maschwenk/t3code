import type { OrchestrationV2QuietRun, OrchestrationV2Run, RunId } from "@t3tools/contracts";
import * as DateTime from "effect/DateTime";

type QuietRunInput = Pick<
  OrchestrationV2Run,
  "id" | "ordinal" | "status" | "requestedAt" | "completedAt"
>;

/** A run that ended without completing shows as it is, so its failure or stop is never hidden. */
const ENDED_UNFINISHED = new Set(["interrupted", "failed", "cancelled", "rolled_back"]);

/**
 * The thread's quiet-run record once `runId` is judged quiet, or null when nothing changes: the
 * run is no longer the latest, ended without completing, or is already recorded. Its own agent
 * can mark it while it still runs. Back-to-back quiet runs keep pointing at the last run before
 * them that was not quiet.
 */
export function nextQuietRun(
  current: OrchestrationV2QuietRun | null | undefined,
  runs: ReadonlyArray<QuietRunInput>,
  runId: RunId,
): OrchestrationV2QuietRun | null {
  let latest: QuietRunInput | undefined;
  let previous: QuietRunInput | undefined;
  for (const run of runs) {
    if (latest === undefined || run.ordinal > latest.ordinal) {
      previous = latest;
      latest = run;
    } else if (previous === undefined || run.ordinal > previous.ordinal) {
      previous = run;
    }
  }
  if (latest?.id !== runId || ENDED_UNFINISHED.has(latest.status) || current?.runId === runId) {
    return null;
  }
  if (previous === undefined) return { runId, shownRun: null };
  if (current?.runId === previous.id) return { runId, shownRun: current.shownRun };
  return {
    runId,
    shownRun: {
      runId: previous.id,
      status: previous.status,
      requestedAt: DateTime.formatIso(previous.requestedAt),
      completedAt: previous.completedAt === null ? null : DateTime.formatIso(previous.completedAt),
    },
  };
}
