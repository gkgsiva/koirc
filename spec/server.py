"""Fake Library server for the specs: OPDS feeds shaped like gkgsiva/library's.
usage: server.py PORT [range]   (with "range" it honours Range requests)"""
import base64, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import quote

RANGE = len(sys.argv) > 2 and sys.argv[2] == "range"
FILES = {1: ("Dune.epub", b"D" * 5000), 2: ("Emma & Co.epub", b"E" * 3000),
         3: ("Shared.epub", b"S" * 2000), 4: ("Broken.epub", None)}
FOLDERS = {10: ("Sci/Fi: Classics", [1, 3]), 11: ("Reads", [2, 3, 4])}
ACQ = "http://opds-spec.org/acquisition"

def feed(entries, extra=""):
    return ('<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><id>x</id><title>T</title>'
            + extra + "".join(entries) + "</feed>").encode()

def book(i):
    n, d = FILES[i]
    cat = '<category term="Dune Saga" label="Series: Dune Saga #1"/>' if i == 1 else ""
    return (f'<entry><title>{n}</title><id>urn:b{i}</id>{cat}<link rel="{ACQ}" href="/opds/files/{i}/{quote(n)}" '
            f'type="application/epub+zip"' + (f' length="{len(d)}"' if d and i != 2 else "") + "/></entry>")

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        want = "Basic " + base64.b64encode(b"me:pw").decode()
        if self.headers.get("Authorization") not in (want, "Bearer tok"):
            self.send_response(401); self.end_headers(); return
        p, _, q = self.path.partition("?")
        if p == "/opds":
            body = feed(['<entry><title>Folders</title><id>f</id><link rel="subsection" href="/opds/folders"/></entry>'])
        elif p == "/opds/folders":
            body = feed([f'<entry><title>{n.replace("&", "&amp;")}</title><id>f{i}</id><link rel="subsection" href="/opds/folders/{i}"/></entry>'
                         for i, (n, _) in FOLDERS.items()])
        elif p.startswith("/opds/folders/"):
            i = int(p.rsplit("/", 1)[1]); ids = FOLDERS[i][1]
            page = int(q.split("=")[1]) if q.startswith("page=") else 1
            chunk = ids[(page - 1) * 2: page * 2]
            nxt = f'<link rel="next" href="{p}?page={page + 1}"/>' if page * 2 < len(ids) else ""
            body = feed([book(b) for b in chunk], nxt)
        elif p.startswith("/opds/files/"):
            data = FILES[int(p.split("/")[3])][1]
            if data is None:
                self.send_response(500); self.end_headers(); return
            r = self.headers.get("Range")
            if RANGE and r:
                s = int(r.split("=")[1].split("-")[0])
                if s >= len(data):
                    self.send_response(416); self.end_headers(); return
                self.send_response(206); data = data[s:]
            else:
                self.send_response(200)
            self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
