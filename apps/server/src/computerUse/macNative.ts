// @effect-diagnostics nodeBuiltinImport:off -- Loaded only by the isolated native worker.
/**
 * Direct macOS calls that xa11y does not expose: events posted to one process,
 * the window server's window list, the menu bar, the system-wide hit test, and
 * what pointer takeover needs (idle time, pointer location, app activation).
 *
 * Pointer events posted to a process reach a background window only when they
 * carry what AppKit reads off an event the window server did not route: the
 * window number (fields 51, 91 and 92), the posting process (field 41, which
 * Chromium checks before accepting a click into an inactive app) and the
 * window-relative location, whose only setter is SkyLight's. With those set
 * the app handles the event where it says, and the user's pointer never moves.
 *
 * CF references cross ffi-rs as BigInt. Short strings and numbers are tagged
 * pointers with the high bit set, which a JS number cannot represent. The
 * worker exits after one request, so CF objects created here are not released
 * individually.
 */
import * as NodeProcess from "node:process";

type Ffi = typeof import("ffi-rs");
type FfiParams = Parameters<Ffi["load"]>[0];
type Rect = { x: number; y: number; width: number; height: number };

export type NativeWindow = { readonly id: number; readonly layer: number; readonly bounds: Rect };
export type MenuItem = {
  readonly title: string | null;
  readonly enabled: boolean;
  readonly shortcut: { readonly character: string; readonly mask: number } | null;
  readonly press: () => boolean;
  readonly children: () => MenuItem[];
  /** Whether the item opens a submenu, even one AppKit fills only when it opens. */
  readonly hasSubmenu: () => boolean;
};

const LIBRARIES = {
  cf: "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
  cg: "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
  ax: "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
  c: "/usr/lib/libSystem.B.dylib",
  sl: "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
} as const;
type Point = { readonly x: number; readonly y: number };
export type PointerWindow = { readonly id: number; readonly bounds: Rect };
/** CGEventField values AppKit reads when it cannot ask the window server about an event. */
const FIELD = {
  clickState: 1,
  sourcePid: 41,
  windowNumber: 51,
  /** The subtype of an AppKit-defined event, stored twice by +[NSEvent otherEventWithType:...]. */
  appKitSubtype: 83,
  appKitSubtypeCopy: 99,
  windowUnderPointer: 91,
  windowThatCanHandle: 92,
} as const;
const MOUSE_TYPE = {
  left: { move: 5, down: 1, up: 2, drag: 6 },
  right: { move: 5, down: 3, up: 4, drag: 7 },
} as const;
const UTF8 = 0x0800_0100;

export async function loadMacNative() {
  const ffi: Ffi = await import("ffi-rs");
  const { DataType: T } = ffi;
  for (const [library, path] of Object.entries(LIBRARIES)) ffi.open({ library, path });
  const call = <R>(
    library: keyof typeof LIBRARIES,
    funcName: string,
    retType: FfiParams["retType"],
    paramsType: FfiParams["paramsType"],
    paramsValue: unknown[],
  ) => ffi.load({ library, funcName, retType, paramsType, paramsValue }) as unknown as R;
  const Ref = T.BigInt;
  const strings = new Map<string, bigint>();
  const cfString = (value: string) => {
    let ref = strings.get(value);
    if (ref === undefined) {
      ref = call<bigint>(
        "cf",
        "CFStringCreateWithCString",
        Ref,
        [Ref, T.String, T.U32],
        [0n, value, UTF8],
      );
      strings.set(value, ref);
    }
    return ref;
  };
  const typeId = (ref: bigint) =>
    ref ? call<number>("cf", "CFGetTypeID", T.I64, [Ref], [ref]) : -1;
  const TYPE = {
    string: call<number>("cf", "CFStringGetTypeID", T.I64, [], []),
    number: call<number>("cf", "CFNumberGetTypeID", T.I64, [], []),
    array: call<number>("cf", "CFArrayGetTypeID", T.I64, [], []),
    boolean: call<number>("cf", "CFBooleanGetTypeID", T.I64, [], []),
  };
  const out = () => ffi.createPointer({ paramsType: [Ref], paramsValue: [0n] });
  const read = (pointer: ReturnType<typeof out>) =>
    ffi.restorePointer({ retType: [Ref], paramsValue: pointer })[0] as unknown as bigint;
  // CGPoint is two doubles, passed and returned by value. ffi-rs's types omit
  // the struct tag its runtime reads.
  const CGPoint = {
    x: T.Double,
    y: T.Double,
    ffiTypeTag: ffi.FFITypeTag.StackStruct,
  } as unknown as FfiParams["retType"];
  const CGSize = {
    width: T.Double,
    height: T.Double,
    ffiTypeTag: ffi.FFITypeTag.StackStruct,
  } as unknown as FfiParams["retType"];
  const cfTrue = () => {
    // RTLD_DEFAULT; kCFBooleanTrue is a data symbol holding the CFBooleanRef.
    const symbol = call<ReturnType<typeof out>[number]>(
      "c",
      "dlsym",
      T.External,
      [Ref, T.String],
      [-2n, "kCFBooleanTrue"],
    );
    return ffi.restorePointer({ retType: [Ref], paramsValue: [symbol] })[0] as unknown as bigint;
  };
  const toNumber = (ref: bigint) => {
    if (typeId(ref) !== TYPE.number) return null;
    const value = ffi.createPointer({ paramsType: [T.Double], paramsValue: [0] });
    call("cf", "CFNumberGetValue", T.Boolean, [Ref, T.I64, T.External], [ref, 13, value[0]]);
    return ffi.restorePointer({ retType: [T.Double], paramsValue: value })[0] as unknown as number;
  };
  const toBoolean = (ref: bigint) =>
    typeId(ref) === TYPE.boolean
      ? call<boolean>("cf", "CFBooleanGetValue", T.Boolean, [Ref], [ref])
      : null;
  const toString = (ref: bigint): string | null => {
    if (typeId(ref) !== TYPE.string) return null;
    const length = call<number>("cf", "CFStringGetLength", T.I64, [Ref], [ref]);
    const size =
      call<number>(
        "cf",
        "CFStringGetMaximumSizeForEncoding",
        T.I64,
        [T.I64, T.U32],
        [length, UTF8],
      ) + 1;
    const buffer = call<bigint>("c", "malloc", Ref, [T.I64], [size]);
    try {
      return call<boolean>(
        "cf",
        "CFStringGetCString",
        T.Boolean,
        [Ref, Ref, T.I64, T.U32],
        [ref, buffer, size, UTF8],
      )
        ? call<string>("c", "strdup", T.String, [Ref], [buffer])
        : null;
    } finally {
      call("c", "free", T.Void, [Ref], [buffer]);
    }
  };
  const toArray = (ref: bigint) => {
    if (typeId(ref) !== TYPE.array) return [];
    const count = call<number>("cf", "CFArrayGetCount", T.I64, [Ref], [ref]);
    return Array.from({ length: count }, (_, index) =>
      call<bigint>("cf", "CFArrayGetValueAtIndex", Ref, [Ref, T.I64], [ref, index]),
    );
  };
  const field = (dictionary: bigint, key: string) =>
    call<bigint>("cf", "CFDictionaryGetValue", Ref, [Ref, Ref], [dictionary, cfString(key)]);
  const attribute = (element: bigint, name: string) => {
    const value = out();
    const error = call<number>(
      "ax",
      "AXUIElementCopyAttributeValue",
      T.I32,
      [Ref, Ref, T.External],
      [element, cfString(name), value[0]],
    );
    return error === 0 ? read(value) : 0n;
  };
  const release = (ref: bigint) => call("cf", "CFRelease", T.Void, [Ref], [ref]);
  const post = (pid: number, event: bigint) => {
    call("cg", "CGEventPostToPid", T.Void, [T.I32, Ref], [pid, event]);
    release(event);
  };
  const setField = (event: bigint, field: number, value: number) =>
    call("cg", "CGEventSetIntegerValueField", T.Void, [Ref, T.U32, T.I64], [event, field, value]);
  /** Makes a posted pointer event land in `window` at `point` as if routed there. */
  const address = (event: bigint, window: PointerWindow, point: Point) => {
    for (const field of [FIELD.windowNumber, FIELD.windowUnderPointer, FIELD.windowThatCanHandle])
      setField(event, field, window.id);
    setField(event, FIELD.sourcePid, NodeProcess.pid);
    call(
      "sl",
      "SLEventSetWindowLocation",
      T.Void,
      [Ref, CGPoint],
      [event, { x: point.x - window.bounds.x, y: point.y - window.bounds.y }],
    );
    call(
      "cg",
      "CGEventSetTimestamp",
      T.Void,
      [Ref, T.U64],
      [event, call<bigint>("c", "mach_absolute_time", T.U64, [], [])],
    );
  };
  /** Whether an element's accessibility size is at most `limit` in both dimensions. */
  const fitsWithin = (element: bigint, limit: { width: number; height: number }) => {
    const size = attribute(element, "AXSize");
    if (!size) return false;
    const value = ffi.createPointer({
      paramsType: [CGSize],
      paramsValue: [{ width: 0, height: 0 }],
    });
    // kAXValueTypeCGSize
    if (
      !call<boolean>(
        "ax",
        "AXValueGetValue",
        T.Boolean,
        [Ref, T.I32, T.External],
        [size, 2, value[0]],
      )
    )
      return false;
    const { width, height } = ffi.restorePointer({
      retType: [CGSize],
      paramsValue: value,
    })[0] as unknown as {
      width: number;
      height: number;
    };
    return width <= limit.width && height <= limit.height;
  };
  const application = (pid: number) =>
    call<bigint>("ax", "AXUIElementCreateApplication", Ref, [T.I32], [pid]);
  const actionNames = (element: bigint) => {
    const names = out();
    return call<number>(
      "ax",
      "AXUIElementCopyActionNames",
      T.I32,
      [Ref, T.External],
      [element, names[0]],
    ) === 0
      ? toArray(read(names)).map(toString)
      : [];
  };

  const menuItem = (element: bigint): MenuItem => {
    const character = toString(attribute(element, "AXMenuItemCmdChar"));
    return {
      title: toString(attribute(element, "AXTitle")),
      enabled: toBoolean(attribute(element, "AXEnabled")) === true,
      shortcut: character
        ? {
            character: character.toLowerCase(),
            mask: toNumber(attribute(element, "AXMenuItemCmdModifiers")) ?? 0,
          }
        : null,
      press: () =>
        call<number>(
          "ax",
          "AXUIElementPerformAction",
          T.I32,
          [Ref, Ref],
          [element, cfString("AXPress")],
        ) === 0,
      // Menu bar items and menu items hold their items inside one AXMenu child.
      children: () =>
        toArray(attribute(element, "AXChildren")).flatMap((child) =>
          toString(attribute(child, "AXRole")) === "AXMenu"
            ? toArray(attribute(child, "AXChildren")).map(menuItem)
            : [menuItem(child)],
        ),
      hasSubmenu: () => toArray(attribute(element, "AXChildren")).length > 0,
    };
  };

  return {
    /** On-screen windows of `pid`, front to back, from the window server. */
    windows(pid: number): NativeWindow[] {
      // kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements
      const list = call<bigint>(
        "cg",
        "CGWindowListCopyWindowInfo",
        Ref,
        [T.U32, T.U32],
        [1 | 16, 0],
      );
      const windows: NativeWindow[] = [];
      for (const entry of toArray(list)) {
        if (toNumber(field(entry, "kCGWindowOwnerPID")) !== pid) continue;
        const bounds = field(entry, "kCGWindowBounds");
        const id = toNumber(field(entry, "kCGWindowNumber"));
        const rect = {
          x: toNumber(field(bounds, "X")),
          y: toNumber(field(bounds, "Y")),
          width: toNumber(field(bounds, "Width")),
          height: toNumber(field(bounds, "Height")),
        };
        if (
          id === null ||
          rect.x === null ||
          rect.y === null ||
          rect.width === null ||
          rect.height === null
        )
          continue;
        windows.push({
          id,
          layer: toNumber(field(entry, "kCGWindowLayer")) ?? 0,
          bounds: rect as Rect,
        });
      }
      release(list);
      return windows;
    },
    /**
     * Posts one pointer transition to `pid` only, addressed to `window` so the
     * app handles it where `point` lies. The app need not be in front and the
     * user's pointer stays where it is.
     */
    postMouse(
      pid: number,
      window: PointerWindow,
      point: Point,
      transition: {
        kind: "move" | "down" | "up" | "drag";
        button: "left" | "right";
        clickState: number;
      },
    ) {
      const event = call<bigint>(
        "cg",
        "CGEventCreateMouseEvent",
        Ref,
        [Ref, T.U32, CGPoint, T.U32],
        [
          0n,
          MOUSE_TYPE[transition.button][transition.kind],
          { x: point.x, y: point.y },
          transition.button === "left" ? 0 : 1,
        ],
      );
      if (transition.clickState) setField(event, FIELD.clickState, transition.clickState);
      address(event, window, point);
      post(pid, event);
    },
    /**
     * Tells `pid` it became (or stopped being) the active app, the way the
     * window server does, without changing the real front app. A button press
     * posted to an app that believes it is inactive makes AppKit raise the
     * window above every other inactive app's; one posted while it believes
     * it is active leaves the window where it is. The flags are what AppKit
     * sets on an activation that names a window.
     */
    postActivation(pid: number, window: PointerWindow, active: boolean) {
      const event = call<bigint>("cg", "CGEventCreate", Ref, [Ref], [0n]);
      // NSEventTypeAppKitDefined; subtype 1 is activated, 2 deactivated.
      call("cg", "CGEventSetType", T.Void, [Ref, T.U32], [event, 13]);
      setField(event, FIELD.windowNumber, window.id);
      for (const field of [FIELD.appKitSubtype, FIELD.appKitSubtypeCopy])
        setField(event, field, active ? 1 : 2);
      if (active) call("cg", "CGEventSetFlags", T.Void, [Ref, T.U64], [event, 0xc0000]);
      call(
        "cg",
        "CGEventSetTimestamp",
        T.Void,
        [Ref, T.U64],
        [event, call<bigint>("c", "mach_absolute_time", T.U64, [], [])],
      );
      post(pid, event);
    },
    /** Posts one scroll wheel event to `pid` only, in pixels, at `point` of `window`. */
    postScroll(
      pid: number,
      window: PointerWindow,
      point: Point,
      wheel: { vertical: number; horizontal: number },
    ) {
      // kCGScrollEventUnitPixel, two wheels: vertical first.
      const event = call<bigint>(
        "cg",
        "CGEventCreateScrollWheelEvent",
        Ref,
        [Ref, T.U32, T.U32, T.I32, T.I32],
        [0n, 0, 2, wheel.vertical, wheel.horizontal],
      );
      call("cg", "CGEventSetLocation", T.Void, [Ref, CGPoint], [event, { x: point.x, y: point.y }]);
      address(event, window, point);
      post(pid, event);
    },
    /**
     * Presses, through accessibility, the element of `pid` at a screen point or
     * its nearest ancestor that offers AXPress. Chromium and WebKit dispatch
     * that as a real click on the element, in the background. False when
     * nothing there is pressable, or when the pressable element is larger than
     * `within`: a press lands at an element's centre, which is wrong for a
     * point chosen inside a canvas or another large clickable area.
     */
    pressAt(pid: number, point: Point, within?: { width: number; height: number }): boolean {
      const element = out();
      if (
        call<number>(
          "ax",
          "AXUIElementCopyElementAtPosition",
          T.I32,
          [Ref, T.Float, T.Float, T.External],
          [application(pid), point.x, point.y, element[0]],
        ) !== 0
      )
        return false;
      let current = read(element);
      for (let level = 0; current && level < 4; level++) {
        if (actionNames(current).includes("AXPress")) {
          if (within && !fitsWithin(current, within)) return false;
          return (
            call<number>(
              "ax",
              "AXUIElementPerformAction",
              T.I32,
              [Ref, Ref],
              [current, cfString("AXPress")],
            ) === 0
          );
        }
        current = attribute(current, "AXParent");
      }
      return false;
    },
    /**
     * Whether `pid` already exposes its web content fully. Chromium and WebKit
     * list actions such as AXPress on web elements only once an assistive app
     * has asked for the enhanced interface. Electron reads this back as set
     * once asked, but never AXManualAccessibility, so that cannot be the check.
     */
    webAccessibilityEnabled: (pid: number) =>
      toBoolean(attribute(application(pid), "AXEnhancedUserInterface")) === true,
    /**
     * Whether `pid` is an Electron app: only Electron answers
     * AXManualAccessibility. Its Chromium lists AXPress on web elements as soon
     * as any assistive app reads them, but performing it does nothing until
     * web accessibility is enabled.
     */
    isElectron: (pid: number) =>
      toBoolean(attribute(application(pid), "AXManualAccessibility")) !== null,
    /**
     * Asks `pid` to expose its web content fully: AXEnhancedUserInterface for
     * Chromium and WebKit, AXManualAccessibility for Electron. Chromium reports
     * an error for the first yet honors it, so the result is not meaningful.
     */
    enableWebAccessibility(pid: number) {
      for (const name of ["AXEnhancedUserInterface", "AXManualAccessibility"])
        call<number>(
          "ax",
          "AXUIElementSetAttributeValue",
          T.I32,
          [Ref, Ref, Ref],
          [application(pid), cfString(name), cfTrue()],
        );
    },
    /** Posts one key transition to `pid` only. The app need not be in front. */
    postKey(pid: number, keyCode: number, down: boolean, flags: number) {
      const event = call<bigint>(
        "cg",
        "CGEventCreateKeyboardEvent",
        Ref,
        [Ref, T.U32, T.Boolean],
        [0n, keyCode, down],
      );
      call("cg", "CGEventSetFlags", T.Void, [Ref, T.U64], [event, flags]);
      post(pid, event);
    },
    /** The process owning the topmost accessibility element at a screen point. */
    pidAt(point: readonly [number, number]): number | undefined {
      const system = call<bigint>("ax", "AXUIElementCreateSystemWide", Ref, [], []);
      const element = out();
      if (
        call<number>(
          "ax",
          "AXUIElementCopyElementAtPosition",
          T.I32,
          [Ref, T.Float, T.Float, T.External],
          [system, point[0], point[1], element[0]],
        ) !== 0
      )
        return undefined;
      const pid = ffi.createPointer({ paramsType: [T.I32], paramsValue: [0] });
      if (
        call<number>(
          "ax",
          "AXUIElementGetPid",
          T.I32,
          [Ref, T.External],
          [read(element), pid[0]],
        ) !== 0
      )
        return undefined;
      return ffi.restorePointer({ retType: [T.I32], paramsValue: pid })[0] as unknown as number;
    },
    /** Whether this process may capture other apps' windows (Screen Recording). */
    canCaptureScreen: () =>
      call<boolean>("cg", "CGPreflightScreenCaptureAccess", T.Boolean, [], []),
    /** Delivered button releases, including synthesized input, in this login session. */
    pointerReleaseCount: (button: "left" | "right") =>
      call<number>(
        "cg",
        "CGEventSourceCounterForEventType",
        T.U32,
        [T.I32, T.U32],
        [0, button === "left" ? 2 : 4],
      ),
    /** A left-button drag event. AppKit text selection requires a click count of one. */
    postDrag(point: { x: number; y: number }, phase: "down" | "move" | "up") {
      const event = call<bigint>(
        "cg",
        "CGEventCreateMouseEvent",
        Ref,
        [Ref, T.U32, CGPoint, T.U32],
        [0n, phase === "down" ? 1 : phase === "up" ? 2 : 6, point, 0],
      );
      try {
        // kCGMouseEventClickState. Leaving this at zero moves the cursor but
        // TextEdit ignores the drag for selection.
        call("cg", "CGEventSetIntegerValueField", T.Void, [Ref, T.U32, T.I64], [event, 1, 1]);
        call("cg", "CGEventPost", T.Void, [T.U32, Ref], [0, event]);
      } finally {
        release(event);
      }
    },
    /** Seconds since the last input event of any type in this login session. */
    idleSeconds: () =>
      call<number>(
        "cg",
        "CGEventSourceSecondsSinceLastEventType",
        T.Double,
        // kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType
        [T.I32, T.U32],
        [0, 0xffff_ffff],
      ),
    /** The pointer's location in global logical points. */
    pointer(): { x: number; y: number } {
      const event = call<bigint>("cg", "CGEventCreate", Ref, [Ref], [0n]);
      const point = call<{ x: number; y: number }>(
        "cg",
        "CGEventGetLocation",
        CGPoint,
        [Ref],
        [event],
      );
      release(event);
      return { x: point.x, y: point.y };
    },
    /** Moves the pointer without generating mouse events, then lets the mouse drive it again. */
    warp(point: { x: number; y: number }) {
      call("cg", "CGWarpMouseCursorPosition", T.I32, [CGPoint], [{ x: point.x, y: point.y }]);
      call("cg", "CGAssociateMouseAndMouseCursorPosition", T.I32, [T.I32], [1]);
    },
    /** Asks `pid` to become the active app. True when the request was accepted. */
    activate: (pid: number) =>
      call<number>(
        "ax",
        "AXUIElementSetAttributeValue",
        T.I32,
        [Ref, Ref, Ref],
        [
          call<bigint>("ax", "AXUIElementCreateApplication", Ref, [T.I32], [pid]),
          cfString("AXFrontmost"),
          cfTrue(),
        ],
      ) === 0,
    /** Top-level menu bar items of `pid`. xa11y's tree omits the menu bar. */
    menuBar(pid: number): MenuItem[] {
      const app = call<bigint>("ax", "AXUIElementCreateApplication", Ref, [T.I32], [pid]);
      const bar = attribute(app, "AXMenuBar");
      return bar ? toArray(attribute(bar, "AXChildren")).map(menuItem) : [];
    },
  };
}
export type MacNative = Awaited<ReturnType<typeof loadMacNative>>;
