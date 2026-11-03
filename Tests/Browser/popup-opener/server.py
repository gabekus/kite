#!/usr/bin/env python3
"""Serves this folder on two origins for the popup opener test (scripts/test-popup-opener.sh).

  python3 server.py PORT_A PORT_B

http://127.0.0.1:PORT_A is the opener's origin and http://localhost:PORT_B the popup's, so the
two pages are cross-origin, like a site and appleid.apple.com or accounts.google.com.
/hop?to=URL answers 302 to URL, so a popup can pass through a third page as OAuth does.
?coop=VALUE on any page sends it as Cross-Origin-Opener-Policy.
"""
import http.server
import sys
import threading
from functools import partial
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parent


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        if url.path == "/hop":
            self.send_response(302)
            self.send_header("Location", query["to"][0])
            self.end_headers()
            return
        super().do_GET()

    def end_headers(self):
        query = parse_qs(urlparse(self.path).query)
        if "coop" in query:
            self.send_header("Cross-Origin-Opener-Policy", query["coop"][0])
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, *args):
        pass


def serve(host, port):
    server = http.server.ThreadingHTTPServer((host, port), partial(Handler, directory=str(ROOT)))
    server.serve_forever()


if __name__ == "__main__":
    port_a, port_b = int(sys.argv[1]), int(sys.argv[2])
    threading.Thread(target=serve, args=("127.0.0.1", port_a), daemon=True).start()
    # "localhost" resolves to 127.0.0.1 in Kite; bind there so it's the same socket family.
    serve("127.0.0.1", port_b)
