import type { Nodes } from "mdast";
import remarkGfm from "remark-gfm";
import remarkParse from "remark-parse";
import { unified } from "unified";

import { decodeHtmlEntities } from "../../lib/markdownDocument";

const parser = unified().use(remarkParse).use(remarkGfm);

export const CODE_BLOCK_SPEECH = "Code block omitted.";

const HTML_TAG = /<!--[\s\S]*?-->|<[^>]*>/g;
const SENTENCE_END = /[.!?…:;]["'”’)\]]*$/;
const BARE_URL = /^(?:https?:\/\/|www\.)/i;

function stripHtml(html: string): string {
  return decodeHtmlEntities(html.replace(HTML_TAG, " "));
}

/** A bare URL is spoken as its host; the rest of it is noise to a listener. */
function spokenUrl(url: string): string {
  return /^(?:https?:\/\/)?(?:www\.)?([^/?#:]+)/i.exec(url)?.[1] ?? url;
}

function inlineText(node: Nodes): string {
  switch (node.type) {
    case "text":
    case "inlineCode":
      return node.value;
    case "break":
      return " ";
    case "html":
      return stripHtml(node.value);
    case "image":
    case "imageReference":
    case "footnoteReference":
      return "";
    case "link": {
      const text = node.children.map(inlineText).join("");
      return BARE_URL.test(text.trim()) ? spokenUrl(text.trim()) : text;
    }
    default:
      return "children" in node ? node.children.map(inlineText).join("") : "";
  }
}

function pushSentence(out: string[], raw: string): void {
  const text = raw.replace(/\s+/g, " ").trim();
  if (!text) return;
  // Speech engines run a heading or list item into the next line without a full stop.
  out.push(SENTENCE_END.test(text) ? text : `${text}.`);
}

function collectBlocks(node: Nodes, out: string[]): void {
  switch (node.type) {
    case "root":
    case "blockquote":
    case "list":
    case "listItem":
      for (const child of node.children) collectBlocks(child, out);
      return;
    case "paragraph":
    case "heading":
      pushSentence(out, inlineText(node));
      return;
    case "code":
      out.push(CODE_BLOCK_SPEECH);
      return;
    case "table":
      for (const row of node.children) {
        pushSentence(
          out,
          row.children
            .map((cell) => inlineText(cell).trim())
            .filter(Boolean)
            .join(", "),
        );
      }
      return;
    case "html":
      pushSentence(out, stripHtml(node.value));
      return;
    default:
      return;
  }
}

/** Markdown as a listener should hear it: syntax, URLs, and code blocks removed. */
export function markdownToSpeechText(markdown: string): string {
  const blocks: string[] = [];
  collectBlocks(parser.parse(markdown), blocks);
  return blocks.join("\n\n");
}

/** Splits at paragraph breaks, then spaces, so each piece fits one utterance. */
export function splitSpeechText(text: string, maxLength: number): string[] {
  const chunks: string[] = [];
  let current = "";
  for (let block of text.split("\n\n")) {
    while (block.length > maxLength) {
      if (current) chunks.push(current);
      current = "";
      const space = block.lastIndexOf(" ", maxLength);
      const end = space > 0 ? space : maxLength;
      chunks.push(block.slice(0, end));
      block = block.slice(end).trimStart();
    }
    if (current && current.length + 2 + block.length > maxLength) {
      chunks.push(current);
      current = "";
    }
    current = current ? `${current}\n\n${block}` : block;
  }
  if (current) chunks.push(current);
  return chunks;
}

export interface ReadAloudVoice {
  readonly identifier: string;
  readonly quality: string;
  readonly language: string;
}

function voiceRank(voice: ReadAloudVoice): number {
  // expo-speech reports iOS premium voices as "Default", so read the tier from the identifier.
  if (voice.identifier.includes(".premium.")) return 2;
  return voice.quality === "Enhanced" || voice.identifier.includes(".enhanced.") ? 1 : 0;
}

/** The best downloaded voice for the locale, or undefined to use the system default. */
export function pickReadAloudVoice(
  voices: ReadonlyArray<ReadAloudVoice>,
  locale: string,
): string | undefined {
  const wanted = locale.replace(/_/g, "-").toLowerCase();
  const language = wanted.split("-")[0];
  let best: { readonly identifier: string; readonly score: number } | undefined;
  for (const voice of voices) {
    const voiceLocale = voice.language.replace(/_/g, "-").toLowerCase();
    const rank = voiceRank(voice);
    if (rank === 0 || voiceLocale.split("-")[0] !== language) continue;
    // The listener's own accent outranks a better voice from another region.
    const score = rank + (voiceLocale === wanted ? 10 : 0);
    if (!best || score > best.score) best = { identifier: voice.identifier, score };
  }
  return best?.identifier;
}
