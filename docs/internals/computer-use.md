# Apps and browser tabs: one vocabulary

Agents use two tool families:

- `computer_*` drives macOS apps through accessibility and posted events ([computerUse/](../../apps/server/src/computerUse)).
- `preview_*` drives T3's browser tabs through Playwright over CDP ([preview/](../../apps/server/src/preview)).

They differ in refs, tree format, action results and coordinates, and even in what `press` means. Codex drives both through one `Target` interface (`getAXState()`, `click(index | [x, y])`, `scroll`, `typeText`, `pressKey`).

## Decision: two families, one vocabulary

Keep both families and their names. Their observe and act tools share one set of steps, refs and output.

- **Not one family with a target selector.** Only observe and act overlap. Everything else is specific to one target: opening, navigation, dialogs, uploads, recording, menus and permissions. Merging would save two tool names. In exchange, every description would have to explain two gating models: apps need macOS and the allowlist, tabs have per-thread ownership.
- **Not a REPL like Codex's `cua_repl`.** Codex's models are trained on it (`@oai/cua-repl` README, "Training"), and the six providers T3 drives are not. On the 2026-11-08 bake-off page, Codex's first `getApp` returned about 23.3k characters. About 3.1k of that was state; the rest was API docs. A REPL also runs agent-written JS on the environment, and its real win, many steps per call, T3 already has with `steps`.
- **Names follow upstream.** `preview_*` belongs to upstream, which merged the per-action browser tools into `preview_act` (https://github.com/pingdotgg/t3code/pull/25423). Renaming them would conflict on every sync. `computer_*` is fork-only, so it is the family that moves toward `preview_act`.

## The shared contract

|                 | Apps today                                            | Tabs today                                                      | Both                                               |
| --------------- | ----------------------------------------------------- | --------------------------------------------------------------- | -------------------------------------------------- |
| Act             | `computer_action`, 1–20 steps                         | `preview_act`, one action; the fork's `preview_execute` batches | `computer_action` / `preview_act`, `steps` 1–20    |
| Element line    | `[17] button "7" (focused) {press} @x,y wxh`          | `- button "7" [ref=t3-3-e17]`                                   | the apps line                                      |
| Refs            | integers, kept while role and name hold, never reused | the prefix changes every response                               | integers per caller and target, kept, never reused |
| Other targeting | exact `name` (+ `role`)                               | Playwright locator, CSS selector                                | `name` + `role`; locators stay tab-only            |
| Act result      | steps run; `~` changed, `+` new, `removed:`, `moved:` | `{}`                                                            | steps run, then that diff                          |
| Coordinates     | pixels of the latest `includeImage` capture           | viewport CSS px, but screenshots are capped at 1280 px wide     | image pixels; the server maps them                 |

Steps use the flat shape and field names of upstream's `preview_act` (`click`, `hover`, `type`, `press`, `scroll`, `drag`). `computer_action` takes them as `steps`; `preview_act` takes one.

Apps alone keep `perform`, `menu` and `wait`. Tabs alone keep `select` and `upload`.

`press` always presses a key. On apps, a left `click` on an element that lists `press` uses its accessibility action ([ComputerUse.ts](../../apps/server/src/computerUse/ComputerUse.ts) `planStep`).

## Refs: one integer scheme

Apps renumber with [`carryRefs`](../../apps/server/src/computerUse/snapshotTree.ts). A ref stays while the element's role and name hold, and a new or renamed element gets a number never used before.

A spike with Playwright 1.60's `page.ariaSnapshot({ mode: "ai" })` checked whether tab refs behave the same. That is the call tab snapshots make. Between snapshots, the page removed one button, renamed another, added two elements and filled a field. The result matched the apps rule:

- 8 of 10 refs carried over.
- The renamed button got a new ref (`e2` became `e11`).
- Removed refs never came back. A lookalike of the removed button got `e13`.
- Iframe elements have refs like `f1e2`.

Navigation is the exception. Playwright restarts at `e1`, so after navigating, `e2` names a different element. That is why tab refs carry a generation prefix today.

For tabs, each caller and tab keeps a map from integer to Playwright ref. Its counter never resets, and navigation clears the map, so an old integer fails as stale rather than reaching a new element. Apps already reject a removed ref the same way.

## What stays different on purpose

- **Tabs only:** navigation, evaluate, `wait_for`, dialogs, uploads, resize, appearance, recording, console and network diagnostics, profiles, tab ownership. Server tabs are headless and need no macOS.
- **Apps only:** menu bar, accessibility actions, open/activate, foreground takeover, sending a focus-stealing app back, the allowlist. macOS only.
- **Delivery:** the verbs are shared, the input paths are not. Apps report `via` per step (accessibility, keyboard event, pointer event, takeover). In the 11-08 bake-off, tab typing was one `insertText` event and tab scrolling was a JS scroll with no wheel event. Tabs should report `via` too.
- **Escape hatch:** pages Playwright can't drive stay reachable through computer tools on T3's own window ([computer/tools.ts](../../apps/server/src/mcp/toolkits/computer/tools.ts)).

## Upstream

Upstream's Cua stack, https://github.com/pingdotgg/t3code/pull/16527 through https://github.com/pingdotgg/t3code/pull/16532, is all open, five of six as drafts; the top layer was updated 2026-11-08. It adds:

- Cua Driver 0.38 as a separate `cua-driver` MCP server on every provider, using Cua's tool names;
- Chrome DevTools MCP for the user's Chrome;
- Cua's cursor;
- a floating window card.

That makes three vocabularies and no shared one. `computer_*` covers the same ground as Cua, but in fork-only files with its own names. If the stack lands, expect conflicts in each provider adapter's MCP wiring and in the presentation table (inferred from the PR file lists), plus a product choice between two computer-use stacks.

Don't wait for the stack and don't adopt its vocabulary:

- Keep the shared formatter and ref map in new fork-only modules, with small hooks into upstream files.
- Offer the tab half upstream once it works.
- When the stack merges, decide whether `computer_*` keeps its native worker or puts this vocabulary over Cua's driver.

## Migration

Agents read tool schemas every session, so new calls depend on nothing old. What does depend on the current names:

- **Injected guidance:** `T3_CODE_BROWSER_TOOL_INSTRUCTIONS` ([orchestrationInstructions.ts](../../packages/provider-core/src/server/orchestrationInstructions.ts)), which the Claude, Codex and ACP adapters send. It names `preview_observe`, `baselineId`, `refPrefix` and `preview_execute`. Computer use has no such block; its guidance lives in the tool descriptions.
- **Client rendering:** [t3McpToolPresentation.ts](../../packages/shared/src/t3McpToolPresentation.ts) has a row for every `preview_*` tool and none for `computer_*`, so computer calls use the generic renderer on web and mobile.
  - Old threads keep their old names and inputs, so the old rows stay.
  - Add computer rows, and resolve steps the way upstream's `ACTION_TOOLS` resolves `preview_act`.
- **Text that names tools:** errors in `ServerBrowser.ts` and `McpHttpServer.ts`.

Add no aliases. Upstream just cut its tool schemas by a third, and a second name per tool would add that back. Old names stay only in the presentation table, so history still renders.
