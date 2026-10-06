import type { Element } from "@crowecawcaw/xa11y";
import * as Schema from "effect/Schema";
import * as NodeTimersPromises from "node:timers/promises";
import { pointerTarget } from "./pointerTarget.ts";
import {
  type NativeSnapshot,
  WorkerRequest,
  type ElementTarget,
  type WorkerResponse,
} from "./protocol.ts";

// Loaded only in a short-lived child. Native accessibility can block or crash;
// it must never load inside the server or Electron's main process.
const decodeRequest = Schema.decodeUnknownSync(Schema.fromJsonString(WorkerRequest));
const MAX_NODES = 400;
const MAX_TEXT = 20_000;
const secure = (element: Element) =>
  /password|secure/i.test(`${element.role} ${String(element.raw.ax_subrole ?? "")}`);
const identityMatches = (element: Element, target: ElementTarget) =>
  element.role === target.role &&
  element.name === target.name &&
  (element.value?.slice(0, 1000) ?? null) === target.value &&
  element.bounds?.x === target.bounds?.x &&
  element.bounds?.y === target.bounds?.y &&
  element.bounds?.width === target.bounds?.width &&
  element.bounds?.height === target.bounds?.height &&
  (target.stableId === null || element.stableId === target.stableId);

async function execute(request: WorkerRequest): Promise<WorkerResponse> {
  // oxlint-disable-next-line t3code/no-global-process-runtime -- This isolated CLI worker runs before an Effect runtime exists.
  if (process.platform !== "darwin") return { ok: false, code: "unavailable" };
  const { App, screenshot, inputSim } = await import("@crowecawcaw/xa11y");
  const app =
    request.kind === "snapshot"
      ? await App.byName(request.app, { timeout: 0 })
      : await App.byPid(request.pid, { timeout: 0 });
  if (app.name !== request.app || app.pid === null) return { ok: false, code: "target_changed" };

  if (request.kind === "action") {
    let element = app.asElement();
    let activeWindow: Element | undefined;
    for (const index of request.target.path) {
      if (secure(element)) return { ok: false, code: "target_changed" };
      const child = (await element.children())[index];
      if (!child) return { ok: false, code: "target_changed" };
      element = child;
      if (element.role === "window" && element.active) activeWindow = element;
    }
    if (
      !identityMatches(element, request.target) ||
      secure(element) ||
      !element.enabled ||
      (element.pid !== null && element.pid !== app.pid)
    )
      return { ok: false, code: "target_changed" };
    const point = pointerTarget(element.bounds, activeWindow?.bounds ?? null);
    if (!point || (await App.foreground({ timeout: 0 })).pid !== app.pid)
      return { ok: false, code: "input_requires_foreground" };
    // Visible OS cursor feedback, even for semantic accessibility actions.
    // The small lead lets a human see the target before the operation happens.
    const input = inputSim();
    await input.moveTo(point);
    await NodeTimersPromises.setTimeout(160);
    if ((await App.foreground({ timeout: 0 })).pid !== app.pid)
      return { ok: false, code: "input_requires_foreground" };
    switch (request.action.kind) {
      case "move":
        break;
      case "click":
        await input.click(point, { button: request.action.button, count: request.action.count });
        break;
      case "scroll":
        await input.scroll(point, request.action.dx, request.action.dy);
        break;
      case "press":
        if (!element.actions.includes("press")) return { ok: false, code: "unsupported_action" };
        await element.press();
        break;
      case "type":
        if (!element.editable) return { ok: false, code: "unsupported_action" };
        if (request.action.replace) await element.setValue(request.action.text);
        else await element.typeText(request.action.text);
        break;
      case "perform":
        if (!element.actions.includes(request.action.action))
          return { ok: false, code: "unsupported_action" };
        await element.performAction(request.action.action);
        break;
    }
    return { ok: true };
  }

  const elements: ElementTarget[] = [];
  let textSize = 0;
  let truncated = false;
  const visit = async (element: Element, path: number[], depth: number): Promise<void> => {
    if (elements.length >= MAX_NODES || textSize >= MAX_TEXT || depth > 8) {
      truncated = true;
      return;
    }
    if (element.pid !== null && element.pid !== app.pid) return;
    // Never return password values, names, or descendants to the agent.
    if (secure(element)) return;
    const value = element.value?.slice(0, 1000) ?? null;
    const name = element.name;
    textSize += (name?.length ?? 0) + (value?.length ?? 0);
    if (textSize > MAX_TEXT) {
      truncated = true;
      return;
    }
    elements.push({
      ref: elements.length + 1,
      role: element.role,
      name,
      value,
      enabled: element.enabled,
      editable: element.editable,
      actions: element.actions,
      path,
      stableId: element.stableId,
      bounds: element.bounds,
    });
    const children = await element.children();
    for (const [index, child] of children.entries()) {
      if (elements.length >= MAX_NODES || textSize >= MAX_TEXT) {
        truncated = true;
        break;
      }
      await visit(child, [...path, index], depth + 1);
    }
  };
  await visit(app.asElement(), [], 0);
  let image: NativeSnapshot["image"];
  if (request.includeImage) {
    const foreground = await App.foreground({ timeout: 0 });
    if (foreground.pid !== app.pid) return { ok: false, code: "capture_requires_foreground" };
    const windows = await app.children();
    const window = windows.find((item) => item.active) ?? windows.find((item) => item.focused);
    if (!window?.bounds) return { ok: false, code: "capture_requires_foreground" };
    const shot = await screenshot({ element: window });
    const png = shot.toPng();
    if (png.length > 8 * 1024 * 1024) return { ok: false, code: "failed" };
    image = {
      data: png.toString("base64"),
      mimeType: "image/png",
      width: shot.width,
      height: shot.height,
    };
  }
  return {
    ok: true,
    snapshot: { app: app.name, pid: app.pid, elements, truncated, ...(image ? { image } : {}) },
  };
}

export async function runComputerUseWorker(): Promise<void> {
  let response: WorkerResponse;
  try {
    let raw = "";
    for await (const chunk of process.stdin) {
      raw += String(chunk);
      if (raw.length > 65_536) throw new Error("Request too large");
    }
    response = await execute(decodeRequest(raw));
  } catch (cause) {
    response = {
      ok: false,
      code:
        cause instanceof Error && /PermissionDenied/.test(cause.name) ? "permissions" : "failed",
    };
  }
  process.stdout.write(JSON.stringify(response));
}
