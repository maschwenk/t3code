import * as Schema from "effect/Schema";

import {
  CommandId,
  ForwardCompatibleArray,
  IsoDateTime,
  ProjectId,
  ScheduledTaskId,
  SecretRef,
  ThreadId,
  TrimmedNonEmptyString,
} from "./baseSchemas.ts";
import { ModelSelection } from "./modelSelection.ts";
import {
  OrchestrationV2Actor,
  OrchestrationV2CreationSource,
  OrchestrationV2ThreadLaunchWorkspaceStrategy,
} from "./orchestrationV2.ts";
import { ProviderInteractionMode, RuntimeMode } from "./providerPolicy.ts";

/** 24-hour "HH:MM" wall-clock time. Mirrors `parseTimeOfDay` on the server. */
const TimeOfDay = TrimmedNonEmptyString.check(
  Schema.isPattern(/^([01]?\d|2[0-3]):([0-5]\d)$/),
).annotate({ description: "Local wall-clock time in 24-hour HH:MM form, such as 09:30." });

export const MIN_SCHEDULED_TASK_INTERVAL_MS = 60_000;

const ScheduledTaskIntervalMs = Schema.Int.check(Schema.isGreaterThan(0)).annotate({
  description: "Positive interval in milliseconds.",
});

const ScheduledTaskIntervalSchedule = Schema.Struct({
  type: Schema.Literal("interval").annotate({
    description: "Select interval scheduling.",
  }),
  everyMs: ScheduledTaskIntervalMs,
}).annotate({
  description: "Run repeatedly after a fixed number of milliseconds.",
});

const ScheduledTaskFixedTimeSchedule = Schema.Struct({
  type: Schema.Literal("fixed_time").annotate({
    description: "Select a fixed local wall-clock time.",
  }),
  timeOfDay: TimeOfDay,
  weekdays: Schema.optional(
    Schema.Array(
      Schema.Int.check(Schema.isBetween({ minimum: 0, maximum: 6 })).annotate({
        description: "Weekday number where 0 is Sunday and 6 is Saturday.",
      }),
    ).annotate({
      description: "Optional weekdays; omit to run every day.",
    }),
  ),
}).annotate({
  description: "Run at a fixed local wall-clock time on selected weekdays.",
});

const ScheduledTaskWebhookSignatureFields = {
  header: TrimmedNonEmptyString.annotate({
    description: "Request header carrying the signature, such as x-hub-signature-256.",
  }),
  encoding: Schema.Literals(["hex", "base64"]).annotate({
    description: "How the HMAC-SHA256 digest is encoded in the header.",
  }),
  prefix: Schema.String.annotate({
    description: "Text before the digest in the header value, such as 'sha256='. Empty for none.",
  }),
};

/** HMAC-SHA256 over the raw request body. The secret is never part of the read model. */
export const ScheduledTaskWebhookSignature = Schema.Struct(
  ScheduledTaskWebhookSignatureFields,
).annotate({ description: "Optional HMAC-SHA256 signature check over the raw request body." });
export type ScheduledTaskWebhookSignature = typeof ScheduledTaskWebhookSignature.Type;

/** Matches how long the relay holds a request for an offline environment. */
export const MAX_WEBHOOK_DELIVERY_AGE_MINUTES = 24 * 60;

const WebhookMaxDeliveryAgeMinutes = Schema.Int.check(
  Schema.isBetween({ minimum: 1, maximum: MAX_WEBHOOK_DELIVERY_AGE_MINUTES }),
).annotate({
  description:
    "Skip requests the relay held longer than this many minutes while the environment was offline. Null runs every request.",
});

const ScheduledTaskWebhookSchedule = Schema.Struct({
  type: Schema.Literal("webhook").annotate({
    description: "Run when the task's webhook URL receives a request.",
  }),
  signature: Schema.NullOr(ScheduledTaskWebhookSignature),
  // Optional so rows saved before this setting existed still decode.
  maxDeliveryAgeMinutes: Schema.optional(Schema.NullOr(WebhookMaxDeliveryAgeMinutes)),
}).annotate({
  description:
    "Run on each request to the task's webhook URL. The prompt may use {{body.path}}, {{headers.name}}, {{query.name}}, {{body}} and {{request}} placeholders.",
});

const ScheduledTaskUpsertWebhookSchedule = Schema.Struct({
  type: Schema.Literal("webhook").annotate({
    description: "Run when the task's webhook URL receives a request.",
  }),
  signature: Schema.optional(
    Schema.NullOr(
      Schema.Struct({
        ...ScheduledTaskWebhookSignatureFields,
        secret: Schema.optional(TrimmedNonEmptyString).annotate({
          description: "Shared signing secret. Omit to keep the stored secret.",
        }),
        secretRef: Schema.optional(SecretRef).annotate({
          description:
            "A secret the user entered through request_secret, used instead of secret. It is consumed by this save.",
        }),
      }),
    ),
  ).annotate({
    description: "Signature check; omit or null to accept requests by URL token only.",
  }),
  maxDeliveryAgeMinutes: Schema.optional(Schema.NullOr(WebhookMaxDeliveryAgeMinutes)),
}).annotate({
  description:
    "Run on each request to the task's webhook URL. The prompt may use {{body.path}}, {{headers.name}}, {{query.name}}, {{body}} and {{request}} placeholders.",
});

/**
 * Read model for persisted schedules. Keep accepting legacy sub-minute rows so
 * users can list, disable, edit, or delete them after the write minimum changes.
 */
export const ScheduledTaskSchedule = Schema.Union([
  ScheduledTaskIntervalSchedule,
  ScheduledTaskFixedTimeSchedule,
  ScheduledTaskWebhookSchedule,
]).annotate({
  description:
    "Structured trigger. Pass an object with type 'interval', 'fixed_time' or 'webhook'.",
});
export type ScheduledTaskSchedule = typeof ScheduledTaskSchedule.Type;

/** Mutation model: newly created or updated interval schedules run at most once per minute. */
export const ScheduledTaskUpsertSchedule = Schema.Union([
  Schema.Struct({
    type: Schema.Literal("interval").annotate({
      description: "Select interval scheduling.",
    }),
    everyMs: ScheduledTaskIntervalMs.check(
      Schema.isGreaterThanOrEqualTo(MIN_SCHEDULED_TASK_INTERVAL_MS),
    ).annotate({
      description: "Interval in milliseconds, with a minimum of 60000 (one minute).",
    }),
  }).annotate({
    description: "Run repeatedly after a fixed number of milliseconds.",
  }),
  ScheduledTaskFixedTimeSchedule,
  ScheduledTaskUpsertWebhookSchedule,
]).annotate({
  description: "Writable trigger. Pass an object with type 'interval', 'fixed_time' or 'webhook'.",
});
export type ScheduledTaskUpsertSchedule = typeof ScheduledTaskUpsertSchedule.Type;

export const ScheduledTaskRunStatus = Schema.Literals(["never", "running", "succeeded", "failed"]);
export type ScheduledTaskRunStatus = typeof ScheduledTaskRunStatus.Type;

/** Run budget for a schedule, such as "check 10 times". */
export const ScheduledTaskMaxRuns = Schema.Int.check(
  Schema.isBetween({ minimum: 1, maximum: 100_000 }),
).annotate({
  description: "Stop after this many runs. Null runs until paused, ended, or deleted.",
});

const ScheduledTaskEndsAt = IsoDateTime.annotate({
  description:
    "No timer run starts after this instant; the schedule then ends on its own. Null has no end time.",
});

/** Where a webhook task receives requests. Present only on webhook tasks. */
export const ScheduledTaskWebhookEndpoint = Schema.Struct({
  /** Environment-relative path including the secret token; works on any origin that reaches the environment. */
  path: TrimmedNonEmptyString,
  /** Public T3 Connect URL, or null when the environment is not linked to T3 Connect. */
  url: Schema.NullOr(TrimmedNonEmptyString),
  hasSecret: Schema.Boolean,
});
export type ScheduledTaskWebhookEndpoint = typeof ScheduledTaskWebhookEndpoint.Type;

export const ScheduledTask = Schema.Struct({
  id: ScheduledTaskId,
  title: TrimmedNonEmptyString,
  prompt: TrimmedNonEmptyString,
  enabled: Schema.Boolean,
  schedule: ScheduledTaskSchedule,
  projectId: ProjectId,
  threadId: Schema.NullOr(ThreadId),
  workspaceStrategy: OrchestrationV2ThreadLaunchWorkspaceStrategy,
  modelSelection: ModelSelection,
  runtimeMode: RuntimeMode,
  interactionMode: ProviderInteractionMode,
  createdBy: OrchestrationV2Actor,
  creationSource: OrchestrationV2CreationSource,
  createdAt: IsoDateTime,
  updatedAt: IsoDateTime,
  nextRunAt: Schema.NullOr(IsoDateTime),
  lastRunAt: Schema.NullOr(IsoDateTime),
  lastRunStatus: ScheduledTaskRunStatus,
  lastRunError: Schema.NullOr(Schema.String),
  runCount: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  // Optional so a client can read a server that predates end conditions.
  endsAt: Schema.optional(Schema.NullOr(ScheduledTaskEndsAt)),
  maxRuns: Schema.optional(Schema.NullOr(ScheduledTaskMaxRuns)),
  webhook: Schema.optional(ScheduledTaskWebhookEndpoint),
});
export type ScheduledTask = typeof ScheduledTask.Type;

/**
 * Where a schedule is in its life. A timer that reached its end time or run
 * budget has no next run while still enabled; that is "ended", which only an
 * edit to the end condition reopens.
 */
export type ScheduledTaskLifecycle = "active" | "paused" | "ended";

export function scheduledTaskLifecycle(
  task: Pick<ScheduledTask, "enabled" | "schedule" | "nextRunAt" | "endsAt" | "maxRuns">,
): ScheduledTaskLifecycle {
  if (!task.enabled) return "paused";
  if (task.schedule.type === "webhook") return "active";
  return task.nextRunAt === null && (task.endsAt != null || task.maxRuns != null)
    ? "ended"
    : "active";
}

const WEEKDAY_NAMES = [
  "Sundays",
  "Mondays",
  "Tuesdays",
  "Wednesdays",
  "Thursdays",
  "Fridays",
  "Saturdays",
] as const;

function formatEvery(everyMs: number): string {
  const minutes = everyMs / 60_000;
  if (!Number.isInteger(minutes)) return `Every ${Math.round(everyMs / 1000)} seconds`;
  if (minutes === 1) return "Every minute";
  if (minutes % 1440 === 0) return minutes === 1440 ? "Every day" : `Every ${minutes / 1440} days`;
  if (minutes % 60 === 0) return minutes === 60 ? "Every hour" : `Every ${minutes / 60} hours`;
  return `Every ${minutes} minutes`;
}

/** Human cadence such as "Every 15 minutes" or "Weekdays at 09:00", shared by clients and agents. */
export function scheduledTaskCadenceLabel(schedule: ScheduledTaskSchedule): string {
  if (schedule.type === "webhook") return "On webhook";
  if (schedule.type === "interval") return formatEvery(schedule.everyMs);
  const days = [...new Set(schedule.weekdays ?? [])].toSorted((a, b) => a - b);
  const time = schedule.timeOfDay;
  if (days.length === 0 || days.length === 7) return `Daily at ${time}`;
  if (days.length === 5 && days.every((day) => day >= 1 && day <= 5)) {
    return `Weekdays at ${time}`;
  }
  return `${days.map((day) => WEEKDAY_NAMES[day]).join(", ")} at ${time}`;
}

export const ScheduledTaskListInput = Schema.Struct({});
export type ScheduledTaskListInput = typeof ScheduledTaskListInput.Type;

export const ScheduledTaskListResult = Schema.Struct({
  // Trigger types grow over time; a client must not lose the whole list over
  // one task it cannot decode.
  tasks: ForwardCompatibleArray(ScheduledTask),
});
export type ScheduledTaskListResult = typeof ScheduledTaskListResult.Type;

export const ScheduledTaskUpsertInput = Schema.Struct({
  id: Schema.optional(ScheduledTaskId),
  requireExisting: Schema.optional(Schema.Boolean).annotate({
    description: "Reject the save if the task no longer exists, for edits from a client form.",
  }),
  commandId: Schema.optional(CommandId),
  title: TrimmedNonEmptyString,
  prompt: TrimmedNonEmptyString,
  enabled: Schema.Boolean,
  schedule: ScheduledTaskUpsertSchedule,
  projectId: ProjectId,
  threadId: Schema.optional(Schema.NullOr(ThreadId)),
  workspaceStrategy: OrchestrationV2ThreadLaunchWorkspaceStrategy,
  modelSelection: ModelSelection,
  runtimeMode: RuntimeMode,
  interactionMode: ProviderInteractionMode,
  createdBy: Schema.optional(OrchestrationV2Actor),
  creationSource: Schema.optional(OrchestrationV2CreationSource),
  /** Omit or null for no end time. Saves replace the whole definition, so edits resend it. */
  endsAt: Schema.optional(Schema.NullOr(ScheduledTaskEndsAt)),
  maxRuns: Schema.optional(Schema.NullOr(ScheduledTaskMaxRuns)),
});
export type ScheduledTaskUpsertInput = typeof ScheduledTaskUpsertInput.Type;

/** Partial update that flips only the enabled flag — never overwrites other fields. */
export const ScheduledTaskSetEnabledInput = Schema.Struct({
  id: ScheduledTaskId,
  enabled: Schema.Boolean,
});
export type ScheduledTaskSetEnabledInput = typeof ScheduledTaskSetEnabledInput.Type;

export const ScheduledTaskDeleteInput = Schema.Struct({
  id: ScheduledTaskId,
});
export type ScheduledTaskDeleteInput = typeof ScheduledTaskDeleteInput.Type;

export const ScheduledTaskRunNowInput = Schema.Struct({
  id: ScheduledTaskId,
});
export type ScheduledTaskRunNowInput = typeof ScheduledTaskRunNowInput.Type;

export const ScheduledTaskRotateWebhookTokenInput = Schema.Struct({
  id: ScheduledTaskId,
});
export type ScheduledTaskRotateWebhookTokenInput = typeof ScheduledTaskRotateWebhookTokenInput.Type;

export const ScheduledTaskWebhookDeliveryId = TrimmedNonEmptyString.pipe(
  Schema.brand("ScheduledTaskWebhookDeliveryId"),
);
export type ScheduledTaskWebhookDeliveryId = typeof ScheduledTaskWebhookDeliveryId.Type;

export const ScheduledTaskWebhookDeliveryOutcome = Schema.Literals([
  "accepted",
  "dispatch_failed",
  "rejected_signature",
  "disabled",
  "rate_limited",
  "expired",
]);
export type ScheduledTaskWebhookDeliveryOutcome = typeof ScheduledTaskWebhookDeliveryOutcome.Type;

export const ScheduledTaskWebhookDeliverySummary = Schema.Struct({
  id: ScheduledTaskWebhookDeliveryId,
  taskId: ScheduledTaskId,
  receivedAt: IsoDateTime,
  method: TrimmedNonEmptyString,
  contentType: Schema.NullOr(Schema.String),
  bodyBytes: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  outcome: ScheduledTaskWebhookDeliveryOutcome,
  /** True when a configured signature matched; false when none was configured. */
  signatureVerified: Schema.Boolean,
  /** Template placeholders that had no value in this request and rendered empty. */
  missingFields: Schema.Array(Schema.String),
  error: Schema.NullOr(Schema.String),
});
export type ScheduledTaskWebhookDeliverySummary = typeof ScheduledTaskWebhookDeliverySummary.Type;

export const ScheduledTaskWebhookDelivery = Schema.Struct({
  ...ScheduledTaskWebhookDeliverySummary.fields,
  query: Schema.String,
  headers: Schema.Record(Schema.String, Schema.String),
  /** Body as UTF-8 text, cut at the log limit; see bodyTruncated. */
  body: Schema.String,
  bodyTruncated: Schema.Boolean,
  renderedPrompt: Schema.NullOr(Schema.String),
});
export type ScheduledTaskWebhookDelivery = typeof ScheduledTaskWebhookDelivery.Type;

export const ScheduledTaskListWebhookDeliveriesInput = Schema.Struct({
  id: ScheduledTaskId,
});
export type ScheduledTaskListWebhookDeliveriesInput =
  typeof ScheduledTaskListWebhookDeliveriesInput.Type;

export const ScheduledTaskListWebhookDeliveriesResult = Schema.Struct({
  deliveries: Schema.Array(ScheduledTaskWebhookDeliverySummary),
});
export type ScheduledTaskListWebhookDeliveriesResult =
  typeof ScheduledTaskListWebhookDeliveriesResult.Type;

export const ScheduledTaskGetWebhookDeliveryInput = Schema.Struct({
  id: ScheduledTaskId,
  deliveryId: ScheduledTaskWebhookDeliveryId,
});
export type ScheduledTaskGetWebhookDeliveryInput = typeof ScheduledTaskGetWebhookDeliveryInput.Type;

export const ScheduledTaskGetWebhookDeliveryResult = Schema.Struct({
  delivery: ScheduledTaskWebhookDelivery,
});
export type ScheduledTaskGetWebhookDeliveryResult =
  typeof ScheduledTaskGetWebhookDeliveryResult.Type;

export const ScheduledTaskMutationResult = Schema.Struct({
  task: ScheduledTask,
});
export type ScheduledTaskMutationResult = typeof ScheduledTaskMutationResult.Type;

export const ScheduledTaskDeleteResult = Schema.Struct({
  id: ScheduledTaskId,
});
export type ScheduledTaskDeleteResult = typeof ScheduledTaskDeleteResult.Type;

export const ScheduledTaskRunNowResult = Schema.Struct({
  task: ScheduledTask,
});
export type ScheduledTaskRunNowResult = typeof ScheduledTaskRunNowResult.Type;

export class ScheduledTaskError extends Schema.TaggedError<ScheduledTaskError>()(
  "ScheduledTaskError",
  {
    message: Schema.String,
    taskId: Schema.optional(ScheduledTaskId),
    cause: Schema.optional(Schema.Defect()),
  },
) {}
