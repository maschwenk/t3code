import { MessageId, RunId, ScheduledTaskId } from "@t3tools/contracts";
import { assert, describe, it } from "@effect/vitest";

import { cleanPromptSuggestion, promptSuggestionSubject } from "./PromptSuggestionFallback.ts";

const RUN_ID = RunId.make("run:current");
const EARLIER_RUN_ID = RunId.make("run:earlier");
const OLDEST_RUN_ID = RunId.make("run:oldest");
const REQUEST_ID = MessageId.make("message:request");
const run = { id: RUN_ID, status: "completed" as const, userMessageId: REQUEST_ID };

function message(
  id: string,
  role: "user" | "assistant",
  text: string,
  options: {
    runId?: RunId;
    createdBy?: "user" | "agent";
    streaming?: boolean;
    scheduled?: boolean;
  } = {},
) {
  return {
    id: MessageId.make(id),
    runId: options.runId ?? RUN_ID,
    role,
    text,
    streaming: options.streaming ?? false,
    createdBy: options.createdBy ?? (role === "user" ? "user" : "agent"),
    ...(options.scheduled ? { scheduledTaskId: ScheduledTaskId.make("task:digest") } : {}),
  } as const;
}

describe("promptSuggestionSubject", () => {
  it("reads the request with its steering messages, the last finished reply, and earlier typed messages newest first", () => {
    const subject = promptSuggestionSubject(
      run,
      [
        message("message:oldest", "user", "check my email", { runId: OLDEST_RUN_ID }),
        message("message:digest", "user", "Run the email digest", {
          runId: EARLIER_RUN_ID,
          scheduled: true,
        }),
        message("message:earlier-a", "user", "mark the posthog one read", {
          runId: EARLIER_RUN_ID,
        }),
        message("message:earlier-b", "user", "is my linkedin", { runId: EARLIER_RUN_ID }),
        message("message:request", "user", "reply to megan that the form is done"),
        message("message:steer", "user", "keep it short"),
        message("message:progress", "assistant", "Opening the thread."),
        message("message:final", "assistant", 'Here is a draft. Say "send" and I\'ll send it.'),
        message("message:streaming", "assistant", "Sending", { streaming: true }),
      ],
      [EARLIER_RUN_ID, OLDEST_RUN_ID],
    );
    assert.deepEqual(subject, {
      request: "reply to megan that the form is done\n\nkeep it short",
      reply: 'Here is a draft. Say "send" and I\'ll send it.',
      earlierRequests: ["is my linkedin", "mark the posthog one read", "check my email"],
    });
  });

  it("keeps an agent wake-up that started the run as its request", () => {
    const subject = promptSuggestionSubject(
      run,
      [
        message("message:request", "user", "Background task finished.", { createdBy: "agent" }),
        message("message:final", "assistant", "CI passed. Want me to merge it?"),
      ],
      [],
    );
    assert.equal(subject?.request, "Background task finished.");
  });

  it("skips runs that did not complete or have no finished reply", () => {
    const messages = [
      message("message:request", "user", "run the tests"),
      message("message:final", "assistant", "Running", { streaming: true }),
    ];
    assert.isNull(promptSuggestionSubject(run, messages, []));
    assert.isNull(promptSuggestionSubject({ ...run, status: "interrupted" }, [messages[0]!], []));
  });
});

describe("cleanPromptSuggestion", () => {
  it("keeps a short single-line suggestion and unwraps quotes", () => {
    assert.equal(cleanPromptSuggestion("send"), "send");
    assert.equal(cleanPromptSuggestion(' "push it" '), "push it");
    assert.equal(cleanPromptSuggestion("“go ahead”"), "go ahead");
  });

  it("drops empty, multi-line, and over-long suggestions", () => {
    assert.isNull(cleanPromptSuggestion("  "));
    assert.isNull(cleanPromptSuggestion('""'));
    assert.isNull(cleanPromptSuggestion("run the tests\nthen push"));
    assert.isNull(cleanPromptSuggestion("a".repeat(100)));
  });
});
