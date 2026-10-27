import { WS_METHODS } from "@t3tools/contracts";
import { createEnvironmentRpcCommand } from "@t3tools/client-runtime/state/runtime";

import { connectionAtomRuntime } from "../connection/runtime";

export const completionNotificationTriage = createEnvironmentRpcCommand(connectionAtomRuntime, {
  label: "environment-data:notifications:triage-completion",
  tag: WS_METHODS.notificationsTriageCompletion,
});
