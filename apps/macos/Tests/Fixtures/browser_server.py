"""Disposable local pages for the native browser smoke and manual UI checks."""

import http.server
import json

PAGE = """<!doctype html><meta charset=utf-8><title>Browser fixture {name}</title>
<style>body{{font:18px system-ui;background:#121820;color:#e8edf4;margin:40px}} a{{color:#8ac7ff}}
input,button{{font:inherit;padding:10px;margin:12px 0}} main{{max-width:600px}}</style>
<main><h1>Browser fixture {name}</h1><p>A local page for navigation and state checks.</p>
<label>Draft <input id=draft placeholder="Keep this while switching tabs"></label><br>
<a id=next href=/two>Go to page two</a><br><br>
<a id=popup href=/two target=_blank>Open page two in a new tab</a><br><br>
<button id=trusted onclick="window.trustedClick=event.isTrusted">Trusted click</button><br>
<button id=spa onclick="history.pushState(null,'','/one?step=2');document.title='Browser fixture SPA'">Change route without reload</button><br>
<button onclick="document.cookie='fixture=shared; path=/';document.getElementById('cookie').textContent=document.cookie">Set test cookie</button>
<p id=cookie></p><label>Upload fixture <input type=file></label>
<form action=/two method=get><input name=search placeholder="Search fixture"><button>Submit form</button></form></main>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/two")
            self.end_headers()
            return
        content = PAGE.format(name="Two" if self.path.startswith("/two") else "One").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(content)


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(json.dumps({"url": f"http://localhost:{server.server_port}/one"}), flush=True)
    server.serve_forever()
