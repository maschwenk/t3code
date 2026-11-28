// @effect-diagnostics globalTimers:off globalRandom:off - Playwright input runs outside the Effect runtime.

import type { Page } from "playwright-core";

type Point = { readonly x: number; readonly y: number };
type Box = Point & { readonly width: number; readonly height: number };
type ClickOptions = { readonly button: "left" | "right" | "middle"; readonly clickCount: number };

// Long text still gets real keystrokes, but its pauses shrink to about this much in total.
const TYPING_PAUSE_BUDGET_MS = 6_000;
const MEAN_KEY_PAUSE_MS = 105;

const lastPointer = new WeakMap<Page, Point>();

const between = (min: number, max: number) => min + Math.random() * (max - min);
const pause = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/** People rarely hit the exact centre of a control. */
export const pointIn = (box: Box): Point => ({
  x: box.x + box.width * between(0.3, 0.7),
  y: box.y + box.height * between(0.3, 0.7),
});

/** Points along a bowed curve that start slow, speed up and settle exactly on `to`. */
const mousePath = (from: Point, to: Point): Point[] => {
  const dx = to.x - from.x;
  const dy = to.y - from.y;
  const distance = Math.hypot(dx, dy);
  const steps = Math.round(Math.min(40, Math.max(8, distance / 15)));
  const bow = distance === 0 ? 0 : between(-0.2, 0.2);
  const control = { x: from.x + dx / 2 - dy * bow, y: from.y + dy / 2 + dx * bow };
  return Array.from({ length: steps }, (_, index) => {
    const linear = (index + 1) / steps;
    const t = linear < 0.5 ? 2 * linear * linear : 1 - (2 - 2 * linear) ** 2 / 2;
    const u = 1 - t;
    return {
      x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
      y: u * u * from.y + 2 * u * t * control.y + t * t * to.y,
    };
  });
};

const startPoint = (page: Page, to: Point): Point => {
  const known = lastPointer.get(page);
  if (known) return known;
  const viewport = page.viewportSize();
  const width = viewport?.width ?? to.x * 2;
  const height = viewport?.height ?? to.y * 2;
  return { x: between(0.2, 0.8) * width, y: between(0.2, 0.8) * height };
};

export const move = async (page: Page, to: Point) => {
  for (const point of mousePath(startPoint(page, to), to)) {
    await page.mouse.move(point.x, point.y);
    lastPointer.set(page, point);
    await pause(between(6, 18));
  }
};

export const click = async (page: Page, to: Point, options: ClickOptions) => {
  await move(page, to);
  await pause(between(60, 180));
  for (let count = 1; count <= options.clickCount; count++) {
    await page.mouse.down({ button: options.button, clickCount: count });
    await pause(between(40, 110));
    await page.mouse.up({ button: options.button, clickCount: count });
    if (count < options.clickCount) await pause(between(70, 140));
  }
};

export const type = async (page: Page, text: string) => {
  const characters = Array.from(text);
  const scale = Math.min(1, TYPING_PAUSE_BUDGET_MS / (characters.length * MEAN_KEY_PAUSE_MS));
  for (const character of characters) {
    // keyboard.type would press Enter or Tab for these, submitting forms or moving focus.
    if (character === "\n" || character === "\r" || character === "\t") {
      await page.keyboard.insertText(character);
    } else {
      await page.keyboard.type(character);
    }
    const hesitation = Math.random() < 0.06 ? between(150, 400) : 0;
    await pause((between(35, 140) + hesitation) * scale);
  }
};
