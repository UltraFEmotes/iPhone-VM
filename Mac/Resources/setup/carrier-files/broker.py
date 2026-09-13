#!/usr/bin/env python3
"""Carrier message broker, run on the companion VM. It is the middleman between the Mac Carrier console
and the phone's web chat app, so neither needs to touch iOS's protected Messages database.

- Serves static files from this folder (so /repo/* keeps working for apt, and /chat.html is the app).
- GET  /api/messages?since=<id>[&number=<n>]  -> new messages (all, or to/from that number)
- POST /api/send   {from,to,body}             -> append a message (used by both Mac and phone)
- GET  /api/lines                             -> known numbers (the Mac publishes these)
- POST /api/lines  {lines:[...]}              -> Mac publishes the number<->name list

Messages persist in carrier-messages.json next to this script. Bind 0.0.0.0 so the phone (over the
USB tether, gateway 192.168.178.1) and the Mac (via ssh->localhost) can both reach it.
"""
import json, os, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
# The code folder may be a read-only 9p share (companion); keep the message store somewhere writable.
STORE = os.environ.get("CARRIER_STORE", "/tmp/carrier-messages.json")
LOCK = threading.Lock()
CT = {".html": "text/html; charset=utf-8", ".js": "application/javascript", ".css": "text/css",
      ".json": "application/json", ".deb": "application/octet-stream", ".gz": "application/gzip"}


def load():
    try:
        with open(STORE) as f:
            return json.load(f)
    except Exception:
        return {"messages": [], "lines": [], "next": 1}


def save(db):
    tmp = STORE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(db, f)
    os.replace(tmp, STORE)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/api/messages":
            since = int(q.get("since", ["0"])[0])
            number = q.get("number", [None])[0]
            with LOCK:
                db = load()
            msgs = [m for m in db["messages"] if m["id"] > since and
                    (number is None or m["from"] == number or m["to"] == number)]
            return self._send(200, {"messages": msgs, "next": db["next"]})
        if u.path == "/api/lines":
            with LOCK:
                return self._send(200, {"lines": load()["lines"]})
        # static file
        rel = u.path.lstrip("/") or "chat.html"
        path = os.path.normpath(os.path.join(HERE, rel))
        if not path.startswith(HERE) or not os.path.isfile(path):
            return self._send(404, {"error": "not found"})
        with open(path, "rb") as f:
            data = f.read()
        return self._send(200, data, CT.get(os.path.splitext(path)[1], "application/octet-stream"))

    def do_POST(self):
        u = urlparse(self.path)
        n = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            body = {}
        if u.path == "/api/send":
            frm = str(body.get("from", "")).strip()
            to = str(body.get("to", "")).strip()
            text = str(body.get("body", ""))
            if not to or not text:
                return self._send(400, {"error": "from/to/body required"})
            with LOCK:
                db = load()
                m = {"id": db["next"], "from": frm, "to": to, "body": text, "ts": time.time(),
                     "kind": body.get("kind", "text")}
                db["messages"].append(m)
                db["next"] += 1
                db["messages"] = db["messages"][-5000:]
                save(db)
            return self._send(200, m)
        if u.path == "/api/lines":
            with LOCK:
                db = load()
                db["lines"] = body.get("lines", [])
                save(db)
            return self._send(200, {"ok": True})
        if u.path == "/api/reset":
            with LOCK:
                save({"messages": [], "lines": load()["lines"], "next": 1})
            return self._send(200, {"ok": True})
        return self._send(404, {"error": "not found"})


def main():
    port = int(os.environ.get("CARRIER_PORT", "8088"))
    ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()


if __name__ == "__main__":
    main()
