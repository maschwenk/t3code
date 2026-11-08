/**
 * The agent cursor, drawn the same everywhere an agent points: the computer-use
 * overlay, the browser panel, recordings, and mobile browser streams. Sizes are
 * CSS px (screen points) so the cursor never grows or shrinks with page zoom.
 */

/** CSS px per artwork unit; 0.055 draws the 480x620 artwork at 26x34 px. */
export const AGENT_CURSOR_SCALE = 0.055;

const px = (units: number) => Math.round(units * AGENT_CURSOR_SCALE * 100) / 100;
// The outline's outer tip sits at (20,20) in artwork units. It is the hotspot.
const TIP = px(20);
const RING = px(520);
const ARROW = "M39 59 L408 370 L186 371 L39 552 Z";

/** A click ring centered on the hotspot, invisible until a ripple plays. */
export const AGENT_CURSOR_RING = `<span data-agent-cursor-ring style="position:absolute;left:${-RING / 2}px;top:${-RING / 2}px;width:${RING}px;height:${RING}px;box-sizing:border-box;border-radius:50%;border:${px(36)}px solid #c79ff7;box-shadow:0 0 0 1px rgba(34,34,34,.35);opacity:0;pointer-events:none"></span>`;

/**
 * A ring and the striped arrow, placed so the arrow's tip sits on the containing
 * block's origin. Inline styles keep host pages' CSS off it. SVG ids are
 * document-global, so give each cursor in one document its own `id`.
 */
export const agentCursorMarkup = (id: string) =>
  `${AGENT_CURSOR_RING}<svg data-agent-cursor-arrow xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 620" style="position:absolute;left:${-TIP}px;top:${-TIP}px;width:${px(480)}px;height:${px(620)}px;overflow:visible;transform-origin:${TIP}px ${TIP}px;filter:drop-shadow(0 2px 3px rgba(0,0,0,.4));pointer-events:none">
<defs><linearGradient id="${id}" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="360" y2="480"><stop offset=".353" stop-color="#c79ff7"/><stop offset=".353" stop-color="#fff"/><stop offset=".387" stop-color="#fff"/><stop offset=".387" stop-color="#8ecdf0"/><stop offset=".578" stop-color="#8ecdf0"/><stop offset=".578" stop-color="#fff"/><stop offset=".615" stop-color="#fff"/><stop offset=".615" stop-color="#c79ff7"/></linearGradient></defs>
<path d="${ARROW}" fill="none" stroke="rgba(255,255,255,.92)" stroke-width="66" stroke-linejoin="miter" stroke-miterlimit="8"/>
<path d="${ARROW}" fill="url(#${id})" stroke="#222" stroke-width="38" stroke-linejoin="miter" stroke-miterlimit="8"/>
</svg>`;

/** Click feedback as Web Animations: the ring ripples out while the arrow dips. */
export const AGENT_CURSOR_CLICK = {
  ripple: {
    keyframes: [
      { transform: "scale(.35)", opacity: 1 },
      { transform: "scale(1.25)", opacity: 0 },
    ],
    timing: { duration: 460, easing: "cubic-bezier(.2,.7,.3,1)" },
  },
  press: {
    keyframes: [{ transform: "scale(1)" }, { transform: "scale(.84)" }, { transform: "scale(1)" }],
    timing: { duration: 200, easing: "ease-out" },
  },
};

/** Plays the click feedback once on a cursor rendered from `agentCursorMarkup`. */
export function playAgentCursorClick(cursor: Element) {
  if (cursor.ownerDocument.defaultView?.matchMedia("(prefers-reduced-motion: reduce)").matches)
    return;
  const { ripple, press } = AGENT_CURSOR_CLICK;
  cursor.querySelector("[data-agent-cursor-ring]")?.animate(ripple.keyframes, ripple.timing);
  cursor.querySelector("[data-agent-cursor-arrow]")?.animate(press.keyframes, press.timing);
}
