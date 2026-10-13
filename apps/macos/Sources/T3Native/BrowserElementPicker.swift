import AppKit
import T3Core
import WebKit

@MainActor final class BrowserElementPicker {
  var onChange: (() -> Void)?
  var onSelection: ((JSON) -> Void)?
  var onError: ((String) -> Void)?
  var active: Bool { token != nil }
  private var token: String?
  private let web: WKWebView
  private let world = WKContentWorld.world(name: "T3BrowserPicker")
  private var handler: Handler?

  init(web: WKWebView) {
    self.web = web
    let handler = Handler()
    handler.owner = self
    self.handler = handler
    web.configuration.userContentController.add(handler, contentWorld: world, name: "t3Element")
  }

  func start() {
    guard !active else { return }
    let token = UUID().uuidString
    self.token = token
    onChange?()
    Task { [weak self] in
      guard let self else { return }
      do {
        _ = try await web.callAsyncJavaScript(
          Self.script, arguments: ["token": token], in: nil, contentWorld: world)
        if self.token == token { web.window?.makeFirstResponder(web) } else { await cleanup(token) }
      } catch {
        guard self.token == token else { return }
        self.token = nil
        onError?("Could not select an element: " + error.localizedDescription)
        onChange?()
      }
    }
  }
  func cancel() {
    guard let token else { return }
    self.token = nil
    onChange?()
    Task { await cleanup(token) }
  }
  private func cleanup(_ token: String) async {
    _ = try? await web.callAsyncJavaScript(
      "if (globalThis.t3Picker?.token === token) globalThis.t3Picker.cancel(); return true;",
      arguments: ["token": token], in: nil, contentWorld: world)
  }
  func dispose() {
    cancel()
    web.configuration.userContentController.removeScriptMessageHandler(
      forName: "t3Element", contentWorld: world)
    handler = nil
  }
  private func receive(_ message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
      let token, body["token"] as? String == token
    else { return }
    self.token = nil
    onChange?()
    guard let element = body["element"], JSONSerialization.isValidJSONObject(element),
      let data = try? JSONSerialization.data(withJSONObject: element), data.count < 64_000,
      let context = try? JSON.decode(data)
    else { return }
    onSelection?(context)
  }
  @MainActor private final class Handler: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserElementPicker?
    func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      owner?.receive(message)
    }
  }

  // A separate content world keeps the page from invoking our message handler or replacing picker helpers.
  private static let script = #"""
    globalThis.t3Picker?.cancel();
    const overlay = document.createElement('div');
    overlay.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;box-sizing:border-box;border:2px solid #6ca7ff;background:#6ca7ff22;display:none;';
    document.documentElement.append(overlay);
    const controller = new AbortController();
    const options = {capture:true, signal:controller.signal};
    const cleanup = () => { controller.abort(); overlay.remove(); delete globalThis.t3Picker; };
    const finish = element => { cleanup(); webkit.messageHandlers.t3Element.postMessage({token,element}); };
    globalThis.t3Picker = {token, cancel:cleanup};
    const target = event => event.composedPath().find(node => node instanceof Element && node !== overlay);
    const path = element => {
      const root = element.getRootNode();
      const parts = [];
      for (let node = element; node instanceof Element; node = node.parentElement) {
        if (node.id && root.querySelectorAll('#' + CSS.escape(node.id)).length === 1) {
          parts.unshift('#' + CSS.escape(node.id)); break;
        }
        const siblings = node.parentElement ? [...node.parentElement.children].filter(s => s.localName === node.localName) : [];
        parts.unshift(CSS.escape(node.localName) + (siblings.length > 1 ? ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')' : ''));
      }
      return (root instanceof ShadowRoot ? path(root.host) + ' >>> ' : '') + parts.join(' > ');
    };
    window.addEventListener('mousemove', event => {
      const element = target(event);
      if (!element) return;
      const rect = element.getBoundingClientRect();
      Object.assign(overlay.style, {display:'block', left:rect.x+'px', top:rect.y+'px', width:rect.width+'px', height:rect.height+'px'});
    }, options);
    for (const name of ['pointerdown','mousedown','mouseup','pointerup']) {
      window.addEventListener(name, event => { event.preventDefault(); event.stopImmediatePropagation(); }, options);
    }
    window.addEventListener('click', event => {
      event.preventDefault(); event.stopImmediatePropagation();
      if (!event.isTrusted) return;
      const element = target(event);
      if (!element) return;
      const clone = element.cloneNode(true);
      clone.querySelectorAll('script,style,input[type=hidden]').forEach(node => node.remove());
      for (const node of [clone, ...clone.querySelectorAll('input,textarea')]) {
        node.removeAttribute('value');
        if (node.localName === 'textarea') node.textContent = '';
      }
      finish({pageUrl:location.href.slice(0,2048), pageTitle:document.title.slice(0,512),
        tagName:element.localName, selector:path(element).slice(0,2048),
        htmlPreview:clone.outerHTML.slice(0,4000), pickedAt:new Date().toISOString()});
    }, options);
    window.addEventListener('keydown', event => {
      if (event.key === 'Escape') { event.preventDefault(); event.stopImmediatePropagation(); finish(null); }
    }, options);
    return true;
    """#
}
