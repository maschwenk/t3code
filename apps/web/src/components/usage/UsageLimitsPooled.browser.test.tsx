import {
  EnvironmentId,
  ProviderDriverKind,
  ProviderInstanceId,
  type ServerProvider,
  UsageLimitSourceId,
} from "@t3tools/contracts";
import { CHATGPT_USAGE_URL } from "@t3tools/shared/usageLimits";
import { describe, expect, it } from "vite-plus/test";

import { render } from "../../../test/render";
import { UsageLimitsPooled } from "./UsageLimitsPooled";

const checkedAt = "2026-10-25T16:00:00.000Z";

function managedChatGpt(instanceId: string, displayName: string): ServerProvider {
  return {
    instanceId: ProviderInstanceId.make(instanceId),
    driver: ProviderDriverKind.make("codex"),
    displayName,
    enabled: true,
    installed: true,
    version: "0.164.0",
    status: "ready",
    auth: { status: "authenticated" },
    checkedAt,
    models: [],
    slashCommands: [],
    skills: [],
    usageLimits: {
      checkedAt,
      windows: [],
      unavailable: { reason: "unsupported", message: "Track usage in ChatGPT." },
      externalUsage: { label: "ChatGPT usage", url: CHATGPT_USAGE_URL },
    },
  };
}

describe("UsageLimitsPooled ChatGPT usage card", () => {
  it("names the managed connections it covers", async () => {
    const presentations = new Map([
      [
        EnvironmentId.make("desk"),
        {
          entry: { target: { label: "Desk" } },
          serverConfig: {
            providers: [
              managedChatGpt("chatgpt_work", "ChatGPT Work"),
              managedChatGpt("chatgpt_personal", "ChatGPT Personal"),
            ],
          },
        },
      ],
    ]);
    await using screen = await render(
      <UsageLimitsPooled presentations={presentations} now={Date.parse(checkedAt)} />,
    );

    await expect
      .element(screen.getByText("ChatGPT Work on Desk, ChatGPT Personal on Desk"))
      .toBeVisible();
    await expect
      .element(screen.getByText("View usage in ChatGPT with your connected account."))
      .toBeVisible();
  });
});

describe("UsageLimitsPooled hub accounts", () => {
  it("shows a rate-limited account's last reading with an out-of-date warning", async () => {
    const claude = ProviderDriverKind.make("claudeAgent");
    const weekly = {
      id: "seven_day",
      kind: "weekly",
      label: "Weekly",
      windowDurationMins: 7 * 24 * 60,
      resetsAt: "2026-10-27T16:00:00.000Z",
    } as const;
    const presentations = new Map([
      [
        EnvironmentId.make("desk"),
        {
          entry: { target: { label: "Desk" } },
          serverConfig: {
            providers: [],
            usageLimitSources: [
              {
                id: UsageLimitSourceId.make("pool"),
                kind: "cliproxy" as const,
                label: "Claude Pool",
                checkedAt,
                accounts: [
                  {
                    id: "fresh.json",
                    driver: claude,
                    email: "fresh@example.com",
                    usageLimits: { checkedAt, windows: [{ ...weekly, usedPercent: 20 }] },
                  },
                  {
                    id: "kept.json",
                    driver: claude,
                    email: "kept@example.com",
                    usageLimits: {
                      checkedAt: "2026-10-25T15:48:00.000Z",
                      windows: [{ ...weekly, usedPercent: 66 }],
                      unavailable: {
                        reason: "probeFailed" as const,
                        message: "The provider rate-limited the hub request (HTTP 429).",
                      },
                    },
                  },
                ],
              },
            ],
          },
        },
      ],
    ]);
    await using screen = await render(
      <UsageLimitsPooled presentations={presentations} now={Date.parse(checkedAt)} />,
    );

    await expect
      .element(screen.getByRole("button", { name: /34% left.*out of date/ }))
      .toBeVisible();
    await expect
      .element(
        screen.getByText(
          "Claude Pool: The provider rate-limited the hub request (HTTP 429). Showing the reading from 12m ago; it may be out of date.",
        ),
      )
      .toBeVisible();
  });
});
