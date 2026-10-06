// @effect-diagnostics nodeBuiltinImport:off globalDate:off globalConsole:off preferSchemaOverJson:off globalErrorInEffectFailure:off anyUnknownInErrorContext:off - Experiment harness run directly with node.
/**
 * Matched trials on the fixture app. Every trial starts a fresh fixture.
 *
 *   claude      headless Claude Code with computer_snapshot + computer_action
 *   claude-jev  the same plus computer_delegate, with a system note to delegate navigation
 *   claude-jev-first  the same, told to always delegate first
 *   claude-jev-optional  computer_delegate offered with no note (Claude decides alone)
 *   jev         computer_delegate alone, no Claude (mechanical floor; text tasks hand back)
 *   jev50       the same with the confidence gate at its 0.5 floor instead of 0.55
 *
 * Usage: node bench.ts --out <dir> [--tasks nested,flat,form] [--arms claude,claude-jev,jev]
 *          [--trials 3] [--model claude-sonnet-5-5] [--jev-config path] [--jev-model typesafe/jev]
 * Writes <out>/results.jsonl; the outcome comes from fixture state, not from the agent's claim.
 */
import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeUtil from "node:util";
import * as Effect from "effect/Effect";
import * as ManagedRuntime from "effect/ManagedRuntime";
import * as ComputerUse from "../../src/computerUse/ComputerUse.ts";
import * as Jev from "../../src/computerUse/jevDelegate.ts";
import * as Fixture from "./fixtureApp.ts";
import { computerLayer } from "./mcpServer.ts";

const { values } = NodeUtil.parseArgs({
  options: {
    out: { type: "string" },
    tasks: { type: "string", default: Fixture.TASKS.map((task) => task.id).join(",") },
    arms: { type: "string", default: "claude,claude-jev,jev" },
    trials: { type: "string", default: "3" },
    model: { type: "string", default: "claude-sonnet-5-5" },
    "jev-config": {
      type: "string",
      default: NodePath.join(NodeOS.homedir(), ".config/jev-browser-use/config.json"),
    },
    "jev-model": { type: "string", default: "typesafe/jev" },
  },
});
const out = NodePath.resolve(values.out ?? "jev-bench");
NodeFS.mkdirSync(out, { recursive: true });
const resultsPath = NodePath.join(out, "results.jsonl");
const server = NodePath.join(import.meta.dirname, "mcpServer.ts");
const tasks = Fixture.TASKS.filter((task) => values.tasks.split(",").includes(task.id));
const arms = values.arms.split(",");
const trials = Number(values.trials);

const readJsonl = (path: string) =>
  NodeFS.existsSync(path)
    ? NodeFS.readFileSync(path, "utf8")
        .trim()
        .split("\n")
        .filter(Boolean)
        .map((line) => JSON.parse(line))
    : [];

const DELEGATE_NOTE =
  "For native apps, hand multi-screen navigation and toggling to computer_delegate with the full goal, then enter any text and verify the result yourself with computer_action or computer_snapshot.";

const DELEGATE_FIRST_NOTE =
  "For native apps, always call computer_delegate first with the full goal. Then finish anything it handed back (such as text entry) and verify the result yourself with computer_action or computer_snapshot.";

const prompt = (task: Fixture.Task) =>
  `${task.goal} The app is already running on this machine. Use the computer tools to do it, then check the result. End your reply with one line: DONE or FAILED.`;

async function runClaude(task: Fixture.Task, arm: string, trial: number) {
  const dir = NodePath.join(out, `${task.id}-${arm}-${trial}`);
  NodeFS.rmSync(dir, { recursive: true, force: true });
  NodeFS.mkdirSync(dir, { recursive: true });
  const statePath = NodePath.join(dir, "state.json");
  const logPath = NodePath.join(dir, "tools.jsonl");
  const mcpConfig = NodePath.join(dir, "mcp.json");
  const delegating = arm.startsWith("claude-jev");
  NodeFS.writeFileSync(
    mcpConfig,
    JSON.stringify({
      mcpServers: {
        t3: {
          command: process.execPath,
          args: [server],
          env: {
            JEV_FIXTURE_STATE: statePath,
            JEV_BENCH_LOG: logPath,
            JEV_DELEGATE: delegating ? "1" : "0",
            JEV_CONFIG: values["jev-config"],
            JEV_MODEL: values["jev-model"],
          },
        },
      },
    }),
  );
  const allowed = [
    "computer_snapshot",
    "computer_action",
    ...(delegating ? ["computer_delegate"] : []),
  ]
    .map((name) => `mcp__t3__${name}`)
    .join(",");
  const startedAt = performance.now();
  const child = NodeChildProcess.spawnSync(
    "claude",
    [
      "-p",
      prompt(task),
      "--model",
      values.model,
      "--setting-sources",
      "",
      "--strict-mcp-config",
      "--mcp-config",
      mcpConfig,
      "--tools",
      "",
      "--allowedTools",
      allowed,
      "--disable-slash-commands",
      "--no-session-persistence",
      "--output-format",
      "json",
      ...(arm === "claude-jev" ? ["--append-system-prompt", DELEGATE_NOTE] : []),
      ...(arm === "claude-jev-first" ? ["--append-system-prompt", DELEGATE_FIRST_NOTE] : []),
    ],
    // An empty working directory keeps project instructions out of the context.
    { cwd: dir, encoding: "utf8", timeout: 300_000, maxBuffer: 16 * 1024 * 1024 },
  );
  const wallMs = Math.round(performance.now() - startedAt);
  let result: Record<string, any> = {};
  try {
    result = JSON.parse(child.stdout);
  } catch {
    result = { parseError: true, status: child.status };
  }
  const tools = readJsonl(logPath);
  const state = JSON.parse(NodeFS.readFileSync(statePath, "utf8")) as Fixture.FixtureState;
  const reply = String(result.result ?? "");
  const usage = result.usage ?? {};
  return {
    task: task.id,
    arm,
    trial,
    model: values.model,
    verified: task.verify(state),
    claimed: /DONE\s*$/.test(reply.trim())
      ? "DONE"
      : /FAILED\s*$/.test(reply.trim())
        ? "FAILED"
        : "none",
    wallMs,
    claudeMs: result.duration_ms,
    claudeApiMs: result.duration_api_ms,
    turns: result.num_turns,
    claudeCostUsd: result.total_cost_usd,
    inputTokens: usage.input_tokens,
    cacheReadTokens: usage.cache_read_input_tokens,
    cacheWriteTokens: usage.cache_creation_input_tokens,
    outputTokens: usage.output_tokens,
    isError: result.is_error,
    toolCalls: tools.length,
    toolCallsByName: Object.fromEntries(
      ["computer_snapshot", "computer_action", "computer_delegate"].map((name) => [
        name,
        tools.filter((entry) => entry.tool === name).length,
      ]),
    ),
    toolMs: tools.reduce((sum, entry) => sum + entry.ms, 0),
    nativeCalls: tools.reduce((sum, entry) => sum + (entry.native ?? 0), 0),
    toolErrors: tools.filter((entry) => entry.isError).length,
    actions: tools.reduce((sum, entry) => sum + (entry.completed ?? 0), 0),
    delegations: tools
      .filter((entry) => entry.tool === "computer_delegate")
      .map((entry) => ({
        status: entry.status,
        decisions: entry.decisions,
        jevMs: entry.jevMs,
      })),
    jevDecisions: tools.reduce((sum, entry) => sum + (entry.decisions ?? 0), 0),
    jevMs: tools.reduce((sum, entry) => sum + (entry.jevMs ?? 0), 0),
    jevCostUsd: tools.reduce((sum, entry) => sum + (entry.jevCostUsd ?? 0), 0),
    fixturePresses: state.presses,
  };
}

async function runJev(task: Fixture.Task, arm: string, trial: number) {
  const dir = NodePath.join(out, `${task.id}-${arm}-${trial}`);
  NodeFS.mkdirSync(dir, { recursive: true });
  const statePath = NodePath.join(dir, "state.json");
  const stats = { requests: 0 };
  const runtime = ManagedRuntime.make(computerLayer({ statePath, stats }));
  const config = await Effect.runPromise(
    Jev.loadJevConfig(values["jev-config"], { model: values["jev-model"] }),
  );
  const startedAt = performance.now();
  const result = await runtime.runPromise(
    Effect.service(ComputerUse.ComputerUse).pipe(
      Effect.flatMap((computer) =>
        Jev.delegate(computer, (request) => Jev.decide(config, request), "bench", {
          app: Fixture.APP,
          goal: task.goal,
          minConfidence: arm === "jev50" ? 0.5 : 0.55,
        }),
      ),
    ),
  );
  const wallMs = Math.round(performance.now() - startedAt);
  await runtime.dispose();
  const state = JSON.parse(NodeFS.readFileSync(statePath, "utf8")) as Fixture.FixtureState;
  return {
    task: task.id,
    arm,
    trial,
    verified: task.verify(state),
    status: result.status,
    wallMs,
    jevDecisions: result.steps.length,
    jevMs: result.steps.reduce((sum, step) => sum + step.jevMs, 0),
    jevCostUsd: result.steps.reduce((sum, step) => sum + (step.costUsd ?? 0), 0),
    jevInputTokens: result.steps.reduce((sum, step) => sum + (step.inputTokens ?? 0), 0),
    steps: result.steps.map((step) => `${step.action} @${step.confidence.toFixed(2)}`),
    fixturePresses: state.presses,
    nativeCalls: stats.requests,
  };
}

// Interleave arms within each trial so drift in API latency hits all arms alike.
for (let trial = 1; trial <= trials; trial++)
  for (const task of tasks)
    for (const arm of arms) {
      const row = arm.startsWith("jev")
        ? await runJev(task, arm, trial)
        : await runClaude(task, arm, trial);
      NodeFS.appendFileSync(resultsPath, `${JSON.stringify(row)}\n`);
      console.log(
        `${row.task} ${row.arm} #${row.trial}: verified=${row.verified} wall=${row.wallMs}ms` +
          ("claudeCostUsd" in row
            ? ` cost=$${row.claudeCostUsd} turns=${row.turns} tools=${row.toolCalls}`
            : ` status=${row.status}`),
      );
    }
