import { describe, expect, it } from "vite-plus/test";

import {
  CODE_BLOCK_SPEECH,
  markdownToSpeechText,
  pickReadAloudVoice,
  splitSpeechText,
} from "./readAloudModel";

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
    { name: "short text stays whole", text: "One.\n\nTwo.", max: 100, expected: ["One.\n\nTwo."] },
    {
      name: "paragraphs pack up to the limit",
      text: "Aaaa.\n\nBbbb.\n\nCccc.",
      max: 13,
      expected: ["Aaaa.\n\nBbbb.", "Cccc."],
    },
    {
      name: "a long paragraph breaks at spaces",
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

describe("pickReadAloudVoice", () => {
  const compactUS = {
    identifier: "com.apple.voice.compact.en-US.Samantha",
    quality: "Default",
    language: "en-US",
  };
  const enhancedUS = {
    identifier: "com.apple.voice.enhanced.en-US.Ava",
    quality: "Enhanced",
    language: "en-US",
  };
  const premiumUS = {
    identifier: "com.apple.voice.premium.en-US.Zoe",
    quality: "Default",
    language: "en-US",
  };
  const premiumGB = {
    identifier: "com.apple.voice.premium.en-GB.Serena",
    quality: "Default",
    language: "en-GB",
  };
  const enhancedDE = {
    identifier: "com.apple.voice.enhanced.de-DE.Anna",
    quality: "Enhanced",
    language: "de-DE",
  };

  it.each([
    {
      name: "premium beats enhanced",
      voices: [compactUS, enhancedUS, premiumUS],
      locale: "en-US",
      expected: premiumUS,
    },
    {
      name: "same region beats a better voice elsewhere",
      voices: [premiumGB, enhancedUS],
      locale: "en-US",
      expected: enhancedUS,
    },
    {
      name: "another region beats a compact voice",
      voices: [compactUS, premiumGB],
      locale: "en_US",
      expected: premiumGB,
    },
    {
      name: "only compact voices use the default",
      voices: [compactUS],
      locale: "en-US",
      expected: undefined,
    },
    {
      name: "another language is never picked",
      voices: [enhancedDE],
      locale: "en-US",
      expected: undefined,
    },
  ])("$name", ({ voices, locale, expected }) => {
    expect(pickReadAloudVoice(voices, locale)).toBe(expected?.identifier);
  });
});
