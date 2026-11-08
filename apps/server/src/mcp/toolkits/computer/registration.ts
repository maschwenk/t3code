import type { McpSchema } from "effect/ai";
import type * as ComputerUse from "../../../computerUse/ComputerUse.ts";
import type { NativeSnapshot } from "../../../computerUse/protocol.ts";
import { formatChanges, formatSnapshot } from "../../../computerUse/snapshotTree.ts";

type Content = McpSchema.CallToolResult["content"][number];

interface ComputerToolContent {
  readonly content: Content[];
  readonly isError: boolean;
}

const imageContent = (observation: ComputerUse.Observation): Content[] =>
  observation.image
    ? [
        {
          type: "image",
          data: new Uint8Array(Buffer.from(observation.image.data, "base64")),
          mimeType: observation.image.mimeType,
        },
      ]
    : [];
const SENT_BACK = "The app came forward on its own and was sent back; the user's app is in front.";

const observationContent = (observation: ComputerUse.Observation): Content[] => [
  {
    type: "text",
    text: [
      ...(observation.sentBack ? [SENT_BACK] : []),
      formatSnapshot(observation, observation.snapshotId),
    ].join("\n"),
  },
  ...imageContent(observation),
];

/** Only what changed since `before`, unless the whole tree was asked for or is shorter. */
function afterBatch(
  snapshot: ComputerUse.Observation,
  before: NativeSnapshot | undefined,
  full: boolean,
) {
  const whole = formatSnapshot(snapshot, snapshot.snapshotId);
  if (full || !before) return whole;
  const changes = formatChanges(before, snapshot, snapshot.snapshotId);
  return changes.length < whole.length ? changes : whole;
}

/** One line per completed step, then why the batch stopped, then the app as it is now. */
function actionContent(result: ComputerUse.ActResult, full: boolean): Content[] {
  const lines = [
    `Completed ${result.completed.length} of ${result.total} steps${
      result.completed.length ? ` (${result.completed.join(", ")})` : ""
    }.`,
    ...(result.sentBack ? [SENT_BACK] : []),
  ];
  if (result.error)
    lines.push(`Step ${result.completed.length + 1} stopped the batch: ${result.error.message}`);
  if (result.snapshotError) lines.push(`No fresh snapshot: ${result.snapshotError.message}`);
  return result.snapshot
    ? [
        {
          type: "text",
          text: `${lines.join("\n")}\n\n${afterBatch(result.snapshot, result.before, full)}`,
        },
        ...imageContent(result.snapshot),
      ]
    : [{ type: "text", text: lines.join("\n") }];
}

/**
 * Renders a computer tool's result as text and window images. McpHttpServer
 * registers these tools, since their results are not JSON; `result` is what
 * the tool's handler in ./handlers.ts returned.
 */
export const renderComputerToolResult = (
  name: "computer_snapshot" | "computer_action" | "computer_open",
  input:
    | { readonly app?: string; readonly activate?: boolean; readonly fullSnapshot?: boolean }
    | undefined,
  result: unknown,
): ComputerToolContent => {
  switch (name) {
    case "computer_snapshot":
      return { content: observationContent(result as ComputerUse.Observation), isError: false };
    case "computer_action": {
      const acted = result as ComputerUse.ActResult;
      return {
        content: actionContent(acted, input?.fullSnapshot === true),
        isError: acted.error !== undefined && acted.completed.length === 0,
      };
    }
    case "computer_open":
      return {
        content: [
          {
            type: "text",
            text: `Opened ${input?.app}${input?.activate ? " in front" : " in the background"}.`,
          },
          ...observationContent(result as ComputerUse.Observation),
        ],
        isError: false,
      };
  }
};
