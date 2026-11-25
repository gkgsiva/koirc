"""Fake Library server for the specs: OPDS feeds shaped like gkgsiva/library's.
usage: server.py PORT [range]   (with "range" it honours Range requests)"""
import base64, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import quote

MODES = sys.argv[2].split(",") if len(sys.argv) > 2 else []
RANGE = "range" in MODES
V23 = "v23" in MODES          # second format, statuses, covers, status/highlight/next API
NOSTATUS = "nostatus" in MODES  # an older Library without PUT .../status
CUT = "cut" in MODES            # the first transfer of each book stops half way (flaky Wi-Fi)
CUT_DONE = set()
WISH = "wish" in MODES          # Auto download lists (the wishlist)
NOADMIN = "noadmin" in MODES    # ... but this account may not change them
WATCHES = {}                    # id -> {"name":, "text":}
import json
FILES = {1: ("Dune.epub", b"D" * 5000), 2: ("Emma & Co.epub", b"E" * 3000),
         3: ("Shared.epub", b"S" * 2000), 4: ("Broken.epub", None),
         5: ("Loose.epub", b"L" * 1000), 6: ("New.epub", b"N" * 1500), 7: ("Shared.pdf", b"P" * 2500)}
STATUS = {1: "Read", 2: "Reading"}  # Library (Hardcover) status, in v23 mode
CALLS = []  # status, highlight and next calls received
ADDED = []  # ids added at run time with /test/add (book 6 joins folder 11)
FOLDERS = {10: ("Sci/Fi: Classics", [1, 3]), 11: ("Reads", [2, 3, 4])}
ACQ = "http://opds-spec.org/acquisition"

def feed(entries, extra=""):
    return ('<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom" xmlns:calibre="http://calibre.name/metadata"><id>x</id><title>T</title>'
            + extra + "".join(entries) + "</feed>").encode()

def book(i):
    n, d = FILES[i]
    folders = "".join(f'<category term="{fn}" label="{fn}"/>' for fn, ids in (v for v in FOLDERS.values()) if i in ids)
    cat = '<category term="Dune Saga" label="Series: Dune Saga #1"/><calibre:series>Dune Saga</calibre:series><calibre:series_index>1.0</calibre:series_index>' if i == 1 else ""
    if V23 and i == 6:
        cat = '<calibre:series>Dune Saga</calibre:series><calibre:series_index>2.0</calibre:series_index>'
    extra = ""
    if V23:
        if STATUS.get(i):
            extra += f"<library:status>{STATUS[i]}</library:status>"
        if i == 3:  # this account's own status and rating (newer servers)
            extra += "<library:status>Reading</library:status><library:reading_status>dnf</library:reading_status><library:my_rating>3.5</library:my_rating>"
        if i == 1:
            extra += '<link rel="http://opds-spec.org/image" href="/covers/1.jpg" type="image/jpeg"/>'
        if i == 3:  # the PDF is listed first; the EPUB is the one taken
            extra += f'<link rel="{ACQ}" href="/opds/files/7/Shared.pdf" type="application/pdf" length="2500"/>'
    au = '<author><name>Frank Herbert</name></author>' if i == 1 else '<author><name>Jane Austen</name></author>'
    prog = PROGRESS.get(i)
    lib = f'<library:progress>{prog[0] if prog else 0}</library:progress><library:added>2026-11-0{i}T00:00:00Z</library:added>'
    if prog:
        lib += f'<library:last_read>{prog[1]}</library:last_read>'
    return (f'<entry><title>{n}</title><summary type="text">About {n}</summary><updated>2026-11-0{i}T00:00:00Z</updated>{au}<id>urn:b{i}</id>{cat}{folders}{lib}{extra}<link rel="{ACQ}" href="/opds/files/{i}/{quote(n)}" '
            f'type="application/epub+zip"' + (f' length="{len(d)}"' if d and i != 2 else "") + "/></entry>")

POSITIONS = []
# book id -> (percent, last read ISO time); book 2 was read on another device, book 3 finished
PROGRESS = {2: (0.5, "2026-11-20T10:00:00Z")}
POS_JSON = {2: '{"cfi": "", "percent": 0.5, "updated_at": 1795600800.0, "source": "reader"}',
            3: '{"cfi": "", "percent": 1.0, "updated_at": 1795514400.0, "source": "reader"}'}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_PUT(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode()
        if self.headers.get("Authorization") is None:
            self.send_response(401); self.end_headers(); return
        if self.path.startswith("/api/downloads/") and self.path.endswith("/status"):
            if NOSTATUS:
                self.send_response(404); self.send_header("Content-Type", "text/html"); self.end_headers(); self.wfile.write(b"<h1>Not Found</h1>"); return
            CALLS.append("status " + self.path.split("/")[3] + " " + body)
            out = b'{"status": "reading", "rating": null}'
            self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
            return
        if self.path.startswith("/api/downloads/") and self.path.endswith("/position"):
            POSITIONS.append(self.path.split("/")[3] + " " + body)
            out = b'{"ok": true}'
            self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
            return
        self.send_response(404); self.end_headers()
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode()
        if self.headers.get("Authorization") is None:
            self.send_response(401); self.end_headers(); return
        if self.path.endswith("/highlights"):
            CALLS.append("highlight " + self.path.split("/")[3] + " " + body)
            out = ('{"id": %d, "note": ""}' % (100 + len(CALLS))).encode()
            self.send_response(201); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
            return
        if self.path == "/api/autofill/watches":
            if NOADMIN:
                self.send_response(403); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}"); return
            d = json.loads(body); i = 10 + len(WATCHES)
            WATCHES[i] = {"name": d["name"], "text": d["text"]}
            out = json.dumps({"id": i, "kind": "manual", "name": d["name"], "text": d["text"]}).encode()
            self.send_response(201); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out); return
        if self.path == "/api/autofill/run":
            CALLS.append("autofill run " + body)
            self.send_response(202); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}"); return
        if self.path.endswith("/next/queue"):
            CALLS.append("nextqueue " + self.path.split("/")[3])
            out = b'{"ok": true}'
            self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
            return
        self.send_response(404); self.end_headers()
    def do_DELETE(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(n)
        if self.path.startswith("/api/autofill/watches/"):
            WATCHES.pop(int(self.path.split("/")[4]), None)
        self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}")
    def do_PATCH(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode()
        if self.path.startswith("/api/autofill/watches/"):
            i = int(self.path.split("/")[4]); WATCHES[i]["text"] = json.loads(body)["text"]
            out = json.dumps({"id": i}).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out); return
        CALLS.append("patch " + self.path.split("/")[3] + " " + body)
        out = b'{"ok": true}'
        self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    def do_GET(self):
        want = "Basic " + base64.b64encode(b"me:pw").decode()
        if self.headers.get("Authorization") not in (want, "Bearer tok"):
            self.send_response(401); self.end_headers(); return
        p, _, q = self.path.partition("?")
        if p == "/test/add":
            ADDED.append(6); FOLDERS[11][1].append(6)
            self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers(); return
        if p.startswith("/api/downloads/") and p.endswith("/position"):
            i = int(p.split("/")[3])
            body = POS_JSON.get(i, '{}').encode()
            self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
            return
        if p.startswith("/api/downloads/") and p.endswith("/next"):
            i = int(p.split("/")[3])
            if i == 2:
                body = b'{"next": {"title": "Persuasion", "download_id": null, "owned": false, "unreleased": false}, "auto_queue": false}'
            elif i == 1:
                body = b'{"next": {"title": "New.epub", "download_id": 6, "owned": true, "unreleased": false}, "auto_queue": false}'
            else:
                body = b'{"next": null, "auto_queue": false}'
            self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
            return
        if p == "/api/autofill":
            if not WISH:
                self.send_response(404); self.send_header("Content-Type", "text/html"); self.end_headers(); self.wfile.write(b"<h1>Not Found</h1>"); return
            out = json.dumps({"watches": [{"id": i, "kind": "manual", "name": w["name"], "text": w["text"], "enabled": True}
                                          for i, w in WATCHES.items()] + [{"id": 99, "kind": "list", "name": "Other", "text": None}],
                              "can_edit": not NOADMIN}).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out); return
        if p.startswith("/api/autofill/watches/") and p.endswith("/items"):
            w = WATCHES.get(int(p.split("/")[4]))
            items = []
            for line in (w["text"] if w else "").split("\n"):
                if " by " in line:
                    t, a = line.rsplit(" by ", 1)
                    items.append({"key": "m:x", "title": t, "author": a, "status": "owned" if t == "Persuasion" else "waiting",
                                  "last_detail": None if t == "Persuasion" else "no results"})
            out = json.dumps({"items": items}).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out); return
        if p == "/test/watches":
            out = json.dumps(WATCHES).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out); return
        if p == "/api/me":
            body = b'{"id": 1, "username": "me", "is_admin": true, "opds_only": false}'
            self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
            return
        if p == "/api/v1":
            routes = ["/api/v1/downloads/<int:download_id>/position", "/api/v1/downloads/<int:download_id>/highlights",
                      "/api/v1/downloads/<int:download_id>/next", "/api/v1/autofill/watches"] + ([] if NOSTATUS else ["/api/v1/downloads/<int:download_id>/status"])
            body = ('{"version": "%s", "auth": "x", "routes": [%s]}' % ("1.32.0" if NOSTATUS else "1.33.0",
                    ", ".join('{"methods": "GET", "path": "%s"}' % r for r in routes))).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
            return
        if p == "/covers/1.jpg":
            body = b"JPEGDATA"
            self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
            return
        if p == "/test/calls":
            body = "\n".join(CALLS).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
            return
        if p == "/test/positions":
            body = "\n".join(POSITIONS).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
            return
        if p == "/opds":
            body = feed(['<entry><title>Recently added</title><id>r</id><link rel="subsection" href="/opds/recent"/></entry>',
                         '<entry><title>Folders</title><id>f</id><link rel="subsection" href="/opds/folders"/></entry>'])
        elif p == "/opds/all":
            ids = [1, 2, 3, 5] + ADDED
            page = int(q.split("=")[1]) if q.startswith("page=") else 1
            nxt = f'<link rel="next" href="/opds/all?page={page + 1}"/>' if page * 2 < len(ids) else ""
            body = feed([book(b) for b in ids[(page - 1) * 2: page * 2]], nxt)
        elif p == "/opds/search":
            words = q.split("=", 1)[1].lower().replace("+", " ").split() if q.startswith("q=") else []
            ids = [b for b in [1, 2, 3, 5] + ADDED if all(w in FILES[b][0].lower() for w in words)]
            body = feed([book(b) for b in ids])
        elif p == "/opds/reading":
            body = feed([book(2)])
        elif p == "/opds/recent":
            body = feed([book(b) for b in ADDED[::-1] + [5, 3, 2, 1]])
        elif p == "/opds/folders":
            body = feed([f'<entry><title>{n.replace("&", "&amp;")}</title><id>f{i}</id><content type="text">{"Series" if i == 10 else "List"} · {len(ids)} books</content><link rel="subsection" href="/opds/folders/{i}"/></entry>'
                         for i, (n, ids) in FOLDERS.items()])
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
            total = len(data)
            if RANGE and r:
                s = int(r.split("=")[1].split("-")[0])
                if s >= len(data):
                    self.send_response(416); self.send_header("Content-Range", f"bytes */{total}"); self.end_headers(); return
                self.send_response(206); data = data[s:]
                self.send_header("Content-Range", f"bytes {s}-{total - 1}/{total}")
            else:
                self.send_response(200)
            self.send_header("Content-Length", str(len(data))); self.end_headers()
            if CUT and p not in CUT_DONE:
                CUT_DONE.add(p)
                self.wfile.write(data[:len(data) // 2]); self.wfile.flush()
                self.close_connection = True
                return
            self.wfile.write(data); return
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
