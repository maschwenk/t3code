import { MessageId, RunId, ScheduledTaskId } from "@t3tools/contracts";
import { assert, describe, it } from "@effect/vitest";

import { completionTriageSubject, earlierTriageRunIds } from "./CompletionNotificationTriage.ts";

const REQUEST_ID = MessageId.make("message:request");
const RUN_ID = RunId.make("run:current");
const run = { id: RUN_ID, status: "completed" as const, userMessageId: REQUEST_ID };

function request(overrides: { createdBy: "user" | "agent" | "system"; scheduled?: boolean }) {
  return {
    id: REQUEST_ID,
    runId: RUN_ID,
    role: "user" as const,
    text: "Check CI on the PR and report anything new.",
    streaming: false,
    createdBy: overrides.createdBy,
    ...(overrides.scheduled ? { scheduledTaskId: ScheduledTaskId.make("task:ci") } : {}),
  };
}

function reply(id: string, text: string, options: { runId?: RunId; streaming?: boolean } = {}) {
  return {
    id: MessageId.make(id),
    runId: options.runId ?? RUN_ID,
    role: "assistant" as const,
    text,
    streaming: options.streaming ?? false,
    createdBy: "agent" as const,
  };
}

describe("completionTriageSubject", () => {
  it("alerts without asking when the user typed the request", () => {
    assert.isNull(
      completionTriageSubject(run, [request({ createdBy: "user" }), reply("message:a", "Done.")]),
    );
  });

  it("triages scheduled check-ins and agent wake-ups on the last finished reply", () => {
    const messages = [
      reply("message:early", "Looking at CI now."),
      reply("message:final", "No new failures; 3 jobs still running."),
      reply("message:blank", "  "),
      reply("message:streaming", "Partial", { streaming: true }),
    ];
    const expected = {
      request: "Check CI on the PR and report anything new.",
      reply: "No new failures; 3 jobs still running.",
      earlierReplies: [],
    };
    assert.deepStrictEqual(
      completionTriageSubject(run, [request({ createdBy: "user", scheduled: true }), ...messages]),
      expected,
    );
    assert.deepStrictEqual(
      completionTriageSubject(run, [request({ createdBy: "agent" }), ...messages]),
      expected,
    );
  });

  it("shows the model what earlier check-ins already reported, newest first", () => {
    const previous = RunId.make("run:previous");
    const silent = RunId.make("run:silent");
    const oldest = RunId.make("run:oldest");
    const subject = completionTriageSubject(
      run,
      [
        reply("message:oldest", "All green. Datadog check needs you to reconnect Charon.", {
          runId: oldest,
        }),
        reply("message:silent-blank", " ", { runId: silent }),
        reply("message:previous-early", "Checking builds.", { runId: previous }),
        reply("message:previous", "All green.", { runId: previous }),
        request({ createdBy: "user", scheduled: true }),
        reply("message:final", "All green. Datadog check still needs Charon."),
      ],
      [previous, silent, oldest],
    );
    assert.deepStrictEqual(subject?.reply, "All green. Datadog check still needs Charon.");
    assert.deepStrictEqual(subject?.earlierReplies, [
      "All green.",
      "All green. Datadog check needs you to reconnect Charon.",
    ]);
  });

  it("alerts without asking when there is nothing to judge", () => {
    const wake = request({ createdBy: "system" });
    assert.isNull(completionTriageSubject(run, [wake]));
    assert.isNull(
      completionTriageSubject({ ...run, status: "failed" }, [wake, reply("message:a", "Broke.")]),
    );
    assert.isNull(completionTriageSubject(undefined, [wake, reply("message:a", "Done.")]));
    assert.isNull(
      completionTriageSubject(run, [
        wake,
        reply("message:other-run", "Done.", { runId: RunId.make("run:other") }),
      ]),
    );
  });
});

describe("earlierTriageRunIds", () => {
  it("picks the three runs just before the completed one, newest first", () => {
    const runs = [5, 1, 4, 2, 6, 3].map((ordinal) => ({
      id: RunId.make(`run:${ordinal}`),
      ordinal,
    }));
    assert.deepStrictEqual(earlierTriageRunIds({ ordinal: 5 }, runs), [
      RunId.make("run:4"),
      RunId.make("run:3"),
      RunId.make("run:2"),
    ]);
    assert.deepStrictEqual(earlierTriageRunIds({ ordinal: 2 }, runs), [RunId.make("run:1")]);
    assert.deepStrictEqual(earlierTriageRunIds(undefined, runs), []);
  });
});
