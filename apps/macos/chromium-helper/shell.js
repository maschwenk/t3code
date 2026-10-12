const api = window.t3Browser;
const notice = document.getElementById("notice");
const address = document.getElementById("address");
const run = async (method, input) => {
  try {
    await api.command(method, input);
  } catch (error) {
    notice.textContent = error.message;
  }
};
for (const method of ["back", "forward", "reload", "stop", "close"]) {
  document.getElementById(method).addEventListener("click", () => run(method));
}
document.getElementById("password").addEventListener("click", () => {
  const box = document.getElementById("password").getBoundingClientRect();
  run("popup", { anchor: { x: box.x, y: box.y, width: box.width, height: box.height } });
});
document.getElementById("navigation").addEventListener("submit", (event) => {
  event.preventDefault();
  run("navigate", { url: address.value });
});
api.onState((state) => {
  if (state.partition && !document.querySelector("webview")) {
    const page = document.createElement("webview");
    page.setAttribute("partition", state.partition);
    page.setAttribute("webpreferences", "contextIsolation=true,sandbox=true,nodeIntegration=false");
    page.src = state.url || "about:blank";
    document.getElementById("page").append(page);
  }
  if (state.url && document.activeElement !== address) address.value = state.url;
  notice.textContent = state.message || "Managed Chromium companion · the live page runs here";
});
run("ready");
