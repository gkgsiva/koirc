"""Fake Library server for the specs: OPDS feeds shaped like gkgsiva/library's.
usage: server.py PORT [range]   (with "range" it honours Range requests)"""
import base64, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import quote

RANGE = len(sys.argv) > 2 and sys.argv[2] == "range"
FILES = {1: ("Dune.epub", b"D" * 5000), 2: ("Emma & Co.epub", b"E" * 3000),
         3: ("Shared.epub", b"S" * 2000), 4: ("Broken.epub", None),
         5: ("Loose.epub", b"L" * 1000)}
FOLDERS = {10: ("Sci/Fi: Classics", [1, 3]), 11: ("Reads", [2, 3, 4])}
ACQ = "http://opds-spec.org/acquisition"

def feed(entries, extra=""):
    return ('<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom" xmlns:calibre="http://calibre.name/metadata"><id>x</id><title>T</title>'
            + extra + "".join(entries) + "</feed>").encode()

def book(i):
    n, d = FILES[i]
    folders = "".join(f'<category term="{fn}" label="{fn}"/>' for fn, ids in (v for v in FOLDERS.values()) if i in ids)
    cat = '<category term="Dune Saga" label="Series: Dune Saga #1"/><calibre:series>Dune Saga</calibre:series><calibre:series_index>1.0</calibre:series_index>' if i == 1 else ""
    au = '<author><name>Frank Herbert</name></author>' if i == 1 else '<author><name>Jane Austen</name></author>'
    return (f'<entry><title>{n}</title><summary type="text">About {n}</summary><updated>2026-11-0{i}T00:00:00Z</updated>{au}<id>urn:b{i}</id>{cat}{folders}<link rel="{ACQ}" href="/opds/files/{i}/{quote(n)}" '
            f'type="application/epub+zip"' + (f' length="{len(d)}"' if d and i != 2 else "") + "/></entry>")

POSITIONS = []

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_PUT(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode()
        if self.headers.get("Authorization") is None:
            self.send_response(401); self.end_headers(); return
        if self.path.startswith("/api/downloads/") and self.path.endswith("/position"):
            POSITIONS.append(self.path.split("/")[3] + " " + body)
            out = b'{"ok": true}'
            self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
            return
        self.send_response(404); self.end_headers()
    def do_GET(self):
        want = "Basic " + base64.b64encode(b"me:pw").decode()
        if self.headers.get("Authorization") not in (want, "Bearer tok"):
            self.send_response(401); self.end_headers(); return
        p, _, q = self.path.partition("?")
        if p == "/test/positions":
            body = "\n".join(POSITIONS).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
            return
        if p == "/opds":
            body = feed(['<entry><title>Recently added</title><id>r</id><link rel="subsection" href="/opds/recent"/></entry>',
                         '<entry><title>Folders</title><id>f</id><link rel="subsection" href="/opds/folders"/></entry>'])
        elif p == "/opds/all":
            ids = [1, 2, 3, 5]
            page = int(q.split("=")[1]) if q.startswith("page=") else 1
            nxt = f'<link rel="next" href="/opds/all?page={page + 1}"/>' if page == 1 else ""
            body = feed([book(b) for b in ids[(page - 1) * 2: page * 2]], nxt)
        elif p == "/opds/reading":
            body = feed([book(2)])
        elif p == "/opds/recent":
            body = feed([book(b) for b in (3, 2, 1)])
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
