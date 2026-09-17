"""Local, side-effect-free fixture for the real WKWebView XCTest suite."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(self.path)
        query = f"?{url.query}" if url.query else ""
        if url.path == "/disconnect":
            # Close without response headers: a real first-load WebKit failure.
            self.close_connection = True
            return
        if url.path.startswith("/redirect/"):
            hop = int(url.path.rsplit("/", 1)[1])
            target = f"/redirect/{hop + 1}" if hop < 50 else "/final"
            self.send_response(302)
            self.send_header("Location", target + query)
            if hop == 1:
                self.send_header("Set-Cookie", "chain=retained; Path=/; SameSite=Lax")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if url.path == "/":
            content = """<button id="redirectBtn" onclick="location.href='/redirect/1'+location.search">Redirects</button>
            <button id="skipBtn" onclick="location.href='/final'+location.search">Skip</button>"""
        else:
            content = url.path + " " + self.headers.get("Cookie", "")
        body = ("<!doctype html><meta name='viewport' content='width=device-width'><body>" + content).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18765), Handler).serve_forever()
