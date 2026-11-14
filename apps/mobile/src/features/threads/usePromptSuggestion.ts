import type { EnvironmentThreadShell } from "@t3tools/client-runtime/state/shell";

import { orchestrationEnvironment } from "../../state/orchestration";
import { useEnvironmentQuery } from "../../state/query";

/**
 * The provider's predicted next prompt, while the run that produced it is the thread's latest
 * completed run. `enabled` must also require the server's `promptSuggestionsEnabled`: older
 * servers decode that missing setting as false, so true proves the subscription exists.
 */
export function usePromptSuggestion(
  thread: EnvironmentThreadShell,
  enabled: boolean,
): string | null {
  const latestRun = thread.latestRun;
  const { data } = useEnvironmentQuery(
    enabled && latestRun !== null
      ? orchestrationEnvironment.v2.promptSuggestion({
          environmentId: thread.environmentId,
          input: { threadId: thread.id },
        })
      : null,
  );
  return data && latestRun?.runId === data.runId && latestRun.status === "completed"
    ? data.text
    : null;
}
