import { MessageId, ScheduledTaskId } from "@t3tools/contracts";
import { assert, describe, it } from "@effect/vitest";

import { completionTriageSubject } from "./CompletionNotificationTriage.ts";

const REQUEST_ID = MessageId.make("message:request");
const run = { status: "completed" as const, userMessageId: REQUEST_ID };

function request(overrides: { createdBy: "user" | "agent" | "system"; scheduled?: boolean }) {
  return {
    id: REQUEST_ID,
    role: "user" as const,
    text: "Check CI on the PR and report anything new.",
    streaming: false,
    createdBy: overrides.createdBy,
    ...(overrides.scheduled ? { scheduledTaskId: ScheduledTaskId.make("task:ci") } : {}),
  };
}

function reply(id: string, text: string, streaming = false) {
  return {
    id: MessageId.make(id),
    role: "assistant" as const,
    text,
    streaming,
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
      reply("message:streaming", "Partial", true),
    ];
    const expected = {
      request: "Check CI on the PR and report anything new.",
      reply: "No new failures; 3 jobs still running.",
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

  it("alerts without asking when there is nothing to judge", () => {
    const wake = request({ createdBy: "system" });
    assert.isNull(completionTriageSubject(run, [wake]));
    assert.isNull(
      completionTriageSubject({ ...run, status: "failed" }, [wake, reply("message:a", "Broke.")]),
    );
    assert.isNull(completionTriageSubject(undefined, [wake, reply("message:a", "Done.")]));
  });
});
