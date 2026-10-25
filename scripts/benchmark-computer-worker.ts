// @effect-diagnostics nodeBuiltinImport:off globalPerformance:off globalConsole:off -- Standalone CLI benchmark.
import * as NodeChildProcess from "node:child_process";
import * as NodeURL from "node:url";

const worker = NodeURL.fileURLToPath(new URL("../apps/server/src/bin.ts", import.meta.url));
const batchSize = 10;
const trials = 7;
const run = (session: boolean) => {
  const started = performance.now();
  for (let i = 0; i < (session ? 1 : batchSize); i++) {
    const result = NodeChildProcess.spawnSync(
      process.execPath,
      [worker, "__computer-use", ...(session ? ["--session"] : [])],
      {
        input: session ? "{}\n".repeat(batchSize) : "{}",
        encoding: "utf8",
        timeout: 12_000,
        env: { ...process.env, ELECTRON_RUN_AS_NODE: "1" },
      },
    );
    if (result.error || result.status !== 0) throw new Error("Worker failed");
    const responses = result.stdout
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
    if (
      responses.length !== (session ? batchSize : 1) ||
      responses.some((response) => response.detail?.stage !== "request")
    )
      throw new Error("Unexpected response: benchmark must stop before native access");
  }
  return performance.now() - started;
};
const single: number[] = [];
const reused: number[] = [];
for (let i = 0; i < trials; i++) {
  // Alternate order to avoid consistently favoring the warmed filesystem cache.
  if (i % 2) {
    reused.push(run(true));
    single.push(run(false));
  } else {
    single.push(run(false));
    reused.push(run(true));
  }
}
const median = (values: number[]) =>
  values.toSorted((a, b) => a - b)[Math.floor(values.length / 2)]!;
console.log(
  JSON.stringify(
    {
      scope: "CLI dispatch only; malformed requests never load native addons or touch apps",
      batchSize,
      trials,
      processes: { single: batchSize, reused: 1 },
      medianMs: { single: median(single), reused: median(reused) },
      samplesMs: { single, reused },
    },
    null,
    2,
  ),
);
