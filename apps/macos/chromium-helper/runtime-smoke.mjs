import * as NodeChildProcess from "node:child_process";
import * as NodeCrypto from "node:crypto";
import * as NodeFSP from "node:fs/promises";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import { WIRE_PREFIX } from "./protocol.mjs";

// Every packaged executable must initialize and authenticate without exposing
// windows, loading extensions or opening the user's managed browser state.
export async function smokeRuntime(app) {
  const home = await NodeFSP.realpath(
    await NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "t3-chromium-smoke-")),
  );
  const token = NodeCrypto.randomBytes(32).toString("hex");
  const environment = {
    ...process.env,
    HOME: home,
    T3_CHROMIUM_STATE: NodePath.join(home, "Library/Application Support/T3Native/Chromium"),
    T3_CHROMIUM_TOKEN: token,
  };
  delete environment.ELECTRON_RUN_AS_NODE;
  delete environment.NODE_OPTIONS;
  const child = NodeChildProcess.spawn(NodePath.join(app, "Contents/MacOS/Electron"), [], {
    env: environment,
    stdio: ["pipe", "pipe", "pipe"],
  });
  let diagnostic = "",
    buffer = "",
    hello = false,
    ready = false,
    stopped = false,
    exited = false;
  let timer;
  try {
    await new Promise((resolve, reject) => {
      const fail = (message) =>
        reject(
          Error(
            "The signed Chromium helper failed its isolated startup check: " +
              message +
              "\n" +
              diagnostic,
          ),
        );
      timer = setTimeout(() => {
        child.kill("SIGTERM");
        fail("timeout");
      }, 15000);
      child.stderr.on("data", (data) => {
        diagnostic = (diagnostic + data).slice(-8192);
      });
      child.once("error", (error) => fail(error.message));
      child.once("exit", (code, signal) => {
        exited = true;
        if (code === 0 && ready && hello && stopped) resolve();
        else fail("exit " + code + " " + signal);
      });
      const send = (id, method) =>
        child.stdin.write(JSON.stringify({ token, id, method, input: {} }) + "\n");
      child.stdout.on("data", (data) => {
        try {
          buffer += data;
          if (buffer.length > 1024 * 1024) throw Error("Oversized startup reply");
          let end;
          while ((end = buffer.indexOf("\n")) >= 0) {
            const line = buffer.slice(0, end);
            buffer = buffer.slice(end + 1);
            if (!line.startsWith(WIRE_PREFIX)) continue;
            const message = JSON.parse(line.slice(WIRE_PREFIX.length));
            if (message.token !== token) throw Error("Unauthenticated startup reply");
            if (message.event === "ready" && !ready) {
              ready = true;
              send("hello", "hello");
            }
            if (message.id === "hello") {
              if (
                message.error ||
                message.result?.version !== 1 ||
                message.result?.engine !== "chromium"
              )
                throw Error("Invalid engine handshake");
              hello = true;
              send("stop", "stopHelper");
            }
            if (message.id === "stop") {
              if (message.error) throw Error(message.error.message);
              stopped = true;
            }
          }
        } catch (error) {
          fail(error.message);
        }
      });
    });
    return { protocol: 1, engine: "chromium", initialized: true, ownedShutdown: true };
  } finally {
    clearTimeout(timer);
    if (!exited) {
      child.stdin.end();
      child.kill("SIGTERM");
      await new Promise((resolve) => {
        const timeout = setTimeout(() => {
          if (!exited) child.kill("SIGKILL");
          resolve();
        }, 2000);
        child.once("exit", () => {
          clearTimeout(timeout);
          resolve();
        });
      });
    }
    await NodeFSP.rm(home, { recursive: true, force: true });
  }
}
