# Serves the handoff test pages on 127.0.0.1:PORT. Usage: python3 server.py [PORT]
import http.server, os, sys, functools
port = int(sys.argv[1]) if len(sys.argv) > 1 else 18795
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=os.path.dirname(os.path.abspath(__file__)))
http.server.ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()
