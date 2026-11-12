import { expect, it } from "@effect/vitest";
import { goalActions, jevRoute } from "./BrowserGoal.ts";

// The format of Playwright 1.60 `ariaSnapshot({ mode: "ai", boxes: true })`.
const tree = `- generic [active] [ref=e1] [box=8,8,1264,704]:
  - heading "Settings" [level=1] [ref=e2] [box=8,8,1264,37]
  - button "Account" [ref=e3] [box=8,204,64,21]
  - button "Say \\"hi\\"" [ref=e4] [box=72,204,63,21]
  - 'button "Step 2: it''s next" [ref=e5] [box=135,204,107,21]'
  - button "Archived" [disabled] [ref=e6] [box=245,204,68,21]
  - generic [ref=e7] [box=313,205,114,18]:
    - checkbox "Weekly digest" [checked] [ref=e8] [box=317,206,13,13]
    - text: Weekly digest
  - button "Edit" [ref=e9] [box=432,204,39,21]
  - button "Edit" [ref=e10] [box=471,204,39,21]
  - button [ref=e11] [box=510,66,316,156]:
    - img [ref=e12] [box=518,69,300,150]
  - link "Billing" [ref=e13] [cursor=pointer] [box=830,205,44,18]:
    - /url: /billing
  - button "Delete workspace" [ref=e14] [box=874,204,122,21]
  - link "map()" [ref=e17] [cursor=pointer] [box=424,3334,54,20]:
    - /url: /docs/Array/map
  - link "map()" [ref=e18] [cursor=pointer] [box=549,5117,54,20]:
    - /url: /docs/Array/map
  - link "Next" [ref=e19] [cursor=pointer] [box=8,600,40,18]:
    - /url: /page/2
  - link "Next" [ref=e20] [cursor=pointer] [box=8,900,40,18]:
    - /url: /page/3
  - tablist [ref=e15] [box=8,225,1264,18]:
    - tab "General" [selected] [ref=e16] [box=8,225,1264,18]`;

it("offers enabled, allowed controls whose name picks out one target", () => {
  expect(goalActions(tree, ["DELETE"]).map((action) => [action.ref, action.description])).toEqual([
    ["e3", 'Click button "Account"'],
    ["e4", 'Click button "Say \\"hi\\""'],
    ["e5", `Click button "Step 2: it's next"`],
    ["e8", 'Click checkbox "Weekly digest" (checked)'],
    ["e13", 'Click link "Billing"'],
    ["e17", 'Click link "map()"'],
    ["e16", 'Click tab "General" (selected)'],
    [undefined, "Scroll the page down"],
    [undefined, "Scroll the page up"],
  ]);
});

const page = (dialog: number, content: number, navigation: number) => {
  const links = (prefix: string, count: number, indent: string) =>
    Array.from({ length: count }, (_, i) => `${indent}- link "${prefix} ${i}" [ref=${prefix}${i}]`);
  return [
    "- generic [ref=root]:",
    "  - complementary [ref=side]:",
    "    - navigation [ref=nav]:",
    ...links("nav", navigation, "      "),
    "  - main [ref=main]:",
    ...links("content", content, "    "),
    "    - navigation [ref=toc]:",
    '      - link "In-article contents" [ref=toc1]',
    ...(dialog ? ['  - dialog "Quick search" [ref=dlg]:', ...links("dialog", dialog, "    ")] : []),
  ].join("\n");
};
const counts = (tree: string) => {
  const refs = goalActions(tree).flatMap((action) => (action.ref ? [action.ref] : []));
  return ["dialog", "content", "nav"].map(
    (prefix) => refs.filter((ref) => ref.startsWith(prefix)).length,
  );
};

it.each([
  { dialog: 10, content: 200, navigation: 200, expected: [10, 120, 120] },
  { dialog: 0, content: 400, navigation: 30, expected: [0, 220, 30] },
  { dialog: 0, content: 20, navigation: 400, expected: [0, 20, 229] },
])(
  "keeps an open dialog and shares the other 250 slots between content and navigation ($expected)",
  ({ dialog, content, navigation, expected }) => {
    expect(counts(page(dialog, content, navigation))).toEqual(expected);
  },
);

it.each([
  {
    config: {},
    expected: {
      endpoint: "https://api.typesafe.ai/v1/systemone",
      key: "TYPESAFE_API_KEY",
      model: "jev-latest",
    },
  },
  {
    config: {
      provider: "my-gateway",
      model: "typesafe/jev",
      endpoint: "https://gateway.example/v1/systemone",
      keyName: "GATEWAY_API_KEY",
    },
    expected: {
      endpoint: "https://gateway.example/v1/systemone",
      key: "GATEWAY_API_KEY",
      model: "typesafe/jev",
    },
  },
  { config: { provider: "my-gateway" }, expected: undefined },
])("routes Jev config $config", ({ config, expected }) => {
  expect(jevRoute(config)).toEqual(expected);
});
