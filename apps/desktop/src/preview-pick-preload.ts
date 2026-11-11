import { ipcRenderer } from "electron";

import { PASSKEY_BRIDGE_ARGUMENT, PASSKEY_REFUSE_ARGUMENT } from "./preview/GuestProtocol.ts";
import { installPasskeyBridge, refuseModalPasskeys } from "./preview/PasskeyBridge.ts";
import "./preview/PickPreload.ts";

// Electron hands webPreferences.additionalArguments to sandboxed preloads in process.argv.
if (process.argv.includes(PASSKEY_BRIDGE_ARGUMENT)) {
  installPasskeyBridge((channel, publicKey) => ipcRenderer.invoke(channel, publicKey));
} else if (process.argv.includes(PASSKEY_REFUSE_ARGUMENT)) {
  refuseModalPasskeys();
}
