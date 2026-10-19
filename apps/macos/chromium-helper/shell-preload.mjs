import { contextBridge, ipcRenderer } from "electron";
contextBridge.exposeInMainWorld("t3Browser", {
  command: (method, input = {}) =>
    ipcRenderer.invoke("t3-native-browser-toolbar", { method, input }),
  onState: (callback) =>
    ipcRenderer.on("t3-native-browser-state", (_event, state) => callback(state)),
});
