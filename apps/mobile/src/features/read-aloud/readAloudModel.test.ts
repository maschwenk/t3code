import { describe, expect, it } from "vite-plus/test";

import { CODE_BLOCK_SPEECH, markdownToSpeechText, splitSpeechText } from "./readAloudModel";

describe("markdownToSpeechText", () => {
  it.each([
    { name: "plain prose", markdown: "Hello there.", expected: "Hello there." },
    {
      name: "headings get a full stop",
      markdown: "## Summary\nThe tests pass.",
      expected: "Summary.\n\nThe tests pass.",
    },
    {
      name: "emphasis and strikethrough",
      markdown: "This is **bold**, _italic_ and ~~gone~~ text.",
      expected: "This is bold, italic and gone text.",
    },
    {
      name: "list markers and task boxes",
      markdown: "- first item\n- [x] shipped it\n\n1. step one!\n2. step two",
      expected: "first item.\n\nshipped it.\n\nstep one!\n\nstep two.",
    },
    {
      name: "links keep their text and drop the URL",
      markdown: "See [the docs](https://example.com/docs?x=1) for more.",
      expected: "See the docs for more.",
    },
    {
      name: "bare URLs are read as their host",
      markdown: "Open https://www.github.com/pingdotgg/t3code/pull/1 and <https://example.com/a>.",
      expected: "Open github.com and example.com.",
    },
    {
      name: "fenced code is replaced",
      markdown: "Run this:\n\n```ts\nconst x = 1;\n```\n\nThen restart.",
      expected: `Run this:\n\n${CODE_BLOCK_SPEECH}\n\nThen restart.`,
    },
    {
      name: "inline code is read as its words",
      markdown: "Call `stopReadAloud` from `ThreadFeed.tsx`.",
      expected: "Call stopReadAloud from ThreadFeed.tsx.",
    },
    {
      name: "tables read row by row",
      markdown: "| File | Lines |\n| --- | ---: |\n| `a.ts` | 12 |\n| b.ts | |",
      expected: "File, Lines.\n\na.ts, 12.\n\nb.ts.",
    },
    {
      name: "quotes, images, rules and html",
      markdown:
        "> Quoted **note**\n\n![diagram](d.png)\n\n---\n\n<details>\n<summary>More &amp; less</summary>\n\nHidden body\n\n</details>\n\n<!-- comment -->",
      expected: "Quoted note.\n\nMore & less.\n\nHidden body.",
    },
    { name: "only code", markdown: "```\nx\n```", expected: CODE_BLOCK_SPEECH },
    { name: "nothing to say", markdown: "![](a.png)\n\n---", expected: "" },
  ])("$name", ({ markdown, expected }) => {
    expect(markdownToSpeechText(markdown)).toBe(expected);
  });
});

describe("splitSpeechText", () => {
  it.each([
    {
      name: "the first sentence goes alone, then pieces grow to twice the one before",
      text: "Hi there. A b. C d. E f. G h.",
      max: 100,
      expected: ["Hi there.", "A b. C d. E f.", "G h."],
    },
    {
      name: "paragraphs and closing quotes end sentences",
      text: 'Lead.\n\nHe said "go." Then left.',
      max: 100,
      expected: ["Lead.", 'He said "go."', "Then left."],
    },
    {
      name: "a long sentence breaks at spaces",
      text: "Lead.\n\none two three four",
      max: 9,
      expected: ["Lead.", "one two", "three", "four"],
    },
    {
      name: "a long word breaks hard",
      text: "abcdefghij",
      max: 4,
      expected: ["abcd", "efgh", "ij"],
    },
    { name: "empty text", text: "", max: 10, expected: [] },
  ])("$name", ({ text, max, expected }) => {
    const chunks = splitSpeechText(text, max);
    expect(chunks).toEqual(expected);
    for (const chunk of chunks) expect(chunk.length).toBeLessThanOrEqual(max);
  });
});
