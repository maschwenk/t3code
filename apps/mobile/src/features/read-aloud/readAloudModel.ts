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

const SENTENCE_GAP = /([.!?…]["'”’)\]]*)\s+/g;

/**
 * Splits at sentences, then spaces. The first piece is one sentence so speech starts quickly;
 * each later piece packs sentences up to twice the one before it, so the next piece is ready
 * before the current one finishes.
 */
export function splitSpeechText(text: string, maxLength: number): string[] {
  const pieces: string[] = [];
  for (const paragraph of text.split("\n\n")) {
    for (let sentence of paragraph.replace(SENTENCE_GAP, "$1\u0000").split("\u0000")) {
      sentence = sentence.trim();
      while (sentence.length > maxLength) {
        const space = sentence.lastIndexOf(" ", maxLength);
        const end = space > 0 ? space : maxLength;
        pieces.push(sentence.slice(0, end));
        sentence = sentence.slice(end).trimStart();
      }
      if (sentence) pieces.push(sentence);
    }
  }
  const chunks: string[] = [];
  for (const piece of pieces) {
    const last = chunks.at(-1);
    const before = chunks.at(-2);
    const limit = before === undefined ? 0 : Math.min(maxLength, before.length * 2);
    if (last !== undefined && last.length + 1 + piece.length <= limit)
      chunks[chunks.length - 1] = `${last} ${piece}`;
    else chunks.push(piece);
  }
  return chunks;
}
