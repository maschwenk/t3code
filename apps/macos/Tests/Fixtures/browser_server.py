"""Disposable local pages for the native browser smoke and manual UI checks."""

import http.server
import json
import time

PAGE = """<!doctype html><meta charset=utf-8><title>Browser fixture {name}</title>
<style>body{{font:18px system-ui;background:#121820;color:#e8edf4;margin:40px}} a{{color:#8ac7ff}}
input,button{{font:inherit;padding:10px;margin:12px 0}} main{{max-width:600px}}</style>
<main><h1>Browser fixture {name}</h1><p>A local page for navigation and state checks.</p>
<label>Draft <input id=draft placeholder="Keep this while switching tabs"></label><br>
<a id=next href=/two>Go to page two</a><br><br>
<a id=popup href=/two target=_blank>Open page two in a new tab</a><br><br>
<button id=trusted onclick="window.trustedClick=event.isTrusted">Trusted click</button><br>
<a id=download href=/download>Download file</a><br>
<a id=slow-download href=/download-slow>Download slowly</a><br>
<a id=long-download href=/download-long>Download slowly for quit check</a><br>
<a id=failed-download href=/download-fail>Fail download</a><br>
<a id=redirect-download href=/download-redirect>Download through redirect</a><br>
<button id=blob-download onclick="const a=document.createElement('a');a.href=window.URL.createObjectURL(new Blob(['native blob download'],{{type:'text/plain'}}));a.download='fixture.txt';a.click();setTimeout(()=>window.URL.revokeObjectURL(a.href),1000)">Download blob</button><br>
<button id=spa onclick="history.pushState(null,'','/one?step=2');document.title='Browser fixture SPA'">Change route without reload</button><br>
<button onclick="document.cookie='fixture=shared; path=/';document.getElementById('cookie').textContent=document.cookie">Set test cookie</button>
<p id=cookie></p><label>Upload fixture <input type=file></label>
<form action=/two method=get><input name=search placeholder="Search fixture"><button>Submit form</button></form></main>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/download-redirect":
            self.send_response(302)
            self.send_header("Location", "/download")
            self.end_headers()
            return
        if self.path.startswith("/download"):
            content = ("native browser download\n" + self.headers.get("Cookie", "")).encode()
            slow = self.path in ("/download-slow", "/download-long")
            failed = self.path == "/download-fail"
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="fixture.txt"')
            self.send_header("Content-Length", str(64 * 65536 if slow or failed else len(content)))
            self.end_headers()
            try:
                if slow:
                    for _ in range(64):
                        self.wfile.write(b"x" * 65536)
                        self.wfile.flush()
                        time.sleep(0.2 if self.path == "/download-long" else 0.03)
                else:
                    self.wfile.write(content)
                if failed:
                    self.close_connection = True
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
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
