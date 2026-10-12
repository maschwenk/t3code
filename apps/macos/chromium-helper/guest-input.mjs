import { ipcRenderer } from "electron";
// Isolated, sandboxed preload: page JavaScript never receives this IPC API.
window.addEventListener(
  "pointerdown",
  (event) => {
    if (event.isTrusted)
      ipcRenderer.send("t3-native-browser-human-input", {
        kind: "pointer",
        x: event.clientX,
        y: event.clientY,
        button: event.button,
      });
  },
  true,
);
window.addEventListener(
  "keydown",
  (event) => {
    if (event.isTrusted)
      ipcRenderer.send("t3-native-browser-human-input", {
        kind: "key",
        key: event.key,
        code: event.code,
      });
  },
  true,
);
window.addEventListener(
  "wheel",
  (event) => {
    if (event.isTrusted) ipcRenderer.send("t3-native-browser-human-input", { kind: "wheel" });
  },
  { capture: true, passive: true },
);
