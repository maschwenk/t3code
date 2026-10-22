import type { McpSchema } from "effect/ai";
import type * as ComputerUse from "../../../computerUse/ComputerUse.ts";
import { formatSnapshot } from "../../../computerUse/snapshotTree.ts";

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
const observationContent = (observation: ComputerUse.Observation): Content[] => [
  { type: "text", text: formatSnapshot(observation, observation.snapshotId) },
  ...imageContent(observation),
];

/** One line per completed step, then why the batch stopped, then the app as it is now. */
function actionContent(result: ComputerUse.ActResult): Content[] {
  const lines = [
    `Completed ${result.completed.length} of ${result.total} steps${
      result.completed.length ? ` (${result.completed.join(", ")})` : ""
    }.`,
  ];
  if (result.error)
    lines.push(`Step ${result.completed.length + 1} stopped the batch: ${result.error.message}`);
  if (result.snapshotError) lines.push(`No fresh snapshot: ${result.snapshotError.message}`);
  return result.snapshot
    ? [
        {
          type: "text",
          text: `${lines.join("\n")}\n\n${formatSnapshot(result.snapshot, result.snapshot.snapshotId)}`,
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
  input: { readonly app?: string; readonly activate?: boolean } | undefined,
  result: unknown,
): ComputerToolContent => {
  switch (name) {
    case "computer_snapshot":
      return { content: observationContent(result as ComputerUse.Observation), isError: false };
    case "computer_action": {
      const acted = result as ComputerUse.ActResult;
      return {
        content: actionContent(acted),
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
