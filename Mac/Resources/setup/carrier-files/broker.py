#!/usr/bin/env python3
"""Carrier message broker, run on the companion VM.

The broker sits between InfernoMac's Carrier console and the guest-side
carrier-agentd process. It also serves the local apt repo and optional static
files from this folder at http://192.168.178.1:8088.
"""
import json
import os
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
STORE = os.environ.get("CARRIER_STORE", "/tmp/carrier-messages.json")
LOCK = threading.Lock()
CT = {
    ".html": "text/html; charset=utf-8",
    ".js": "application/javascript",
    ".css": "text/css",
    ".json": "application/json",
    ".deb": "application/octet-stream",
    ".gz": "application/gzip",
}


def _clean_number(value):
    text = str(value or "").strip()
    if text.upper() == "ADMIN":
        return "ADMIN"
    return "".join(re.findall(r"[0-9+]", text))


def _safe_int(value, default=0):
    try:
        return int(value)
    except Exception:
        return default


def _fresh_db():
    return {"messages": [], "lines": [], "next": 1, "clip": {"text": "", "seq": 0, "source": ""}}


def load():
    try:
        with open(STORE) as f:
            db = json.load(f)
        if not isinstance(db, dict):
            db = _fresh_db()
    except Exception:
        db = _fresh_db()

    if not isinstance(db.get("messages"), list):
        db["messages"] = []
    if not isinstance(db.get("lines"), list):
        db["lines"] = []
    if not isinstance(db.get("clip"), dict):
        db["clip"] = {"text": "", "seq": 0, "source": ""}
    db["clip"].setdefault("text", "")
    db["clip"].setdefault("seq", 0)
    db["clip"].setdefault("source", "")

    high = 0
    for message in db["messages"]:
        if isinstance(message, dict):
            high = max(high, _safe_int(message.get("id"), 0))
    db["next"] = max(_safe_int(db.get("next"), 1), high + 1)
    return db


def save(db):
    tmp = STORE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(db, f)
    os.replace(tmp, STORE)


def _matches_number(message, number):
    if not number:
        return True
    return _clean_number(message.get("from")) == number or _clean_number(message.get("to")) == number


def _line_list(value):
    if not isinstance(value, list):
        return None
    lines = []
    for item in value:
        if isinstance(item, dict):
            number = _clean_number(item.get("number"))
            name = str(item.get("name") or "").strip()
            vm_id = str(item.get("vm_id") or item.get("vmID") or "").strip()
            if number:
                line = {"number": number}
                if name:
                    line["name"] = name
                if vm_id:
                    line["vm_id"] = vm_id
                lines.append(line)
        else:
            number = _clean_number(item)
            if number:
                lines.append({"number": number})
    return lines


class H(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "content-type")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def do_OPTIONS(self):
        self._send(204, b"")

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/api/health":
            with LOCK:
                db = load()
            return self._send(200, {"ok": True, "next": db["next"], "messages": len(db["messages"])})
        if u.path == "/api/messages":
            since = _safe_int(q.get("since", ["0"])[0], 0)
            number = _clean_number(q.get("number", [""])[0])
            with LOCK:
                db = load()
            msgs = [
                m for m in db["messages"]
                if isinstance(m, dict) and _safe_int(m.get("id"), 0) > since and _matches_number(m, number)
            ]
            return self._send(200, {"messages": msgs, "next": db["next"]})
        if u.path == "/api/lines":
            with LOCK:
                return self._send(200, {"lines": load()["lines"]})
        if u.path == "/clip":
            with LOCK:
                return self._send(200, load().get("clip", {"text": "", "seq": 0, "source": ""}))

        rel = u.path.lstrip("/") or "chat.html"
        path = os.path.normpath(os.path.join(HERE, rel))
        if os.path.commonpath([HERE, path]) != HERE or not os.path.isfile(path):
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
            frm = _clean_number(body.get("from"))
            to = _clean_number(body.get("to"))
            text = str(body.get("body", ""))
            source = str(body.get("source", "")).strip()[:32]
            client_id = str(body.get("client_id", "")).strip()[:160]
            if not to or not text:
                return self._send(400, {"error": "from/to/body required"})
            with LOCK:
                db = load()
                if client_id:
                    for message in db["messages"]:
                        if isinstance(message, dict) and message.get("client_id") == client_id:
                            return self._send(200, message)
                message = {
                    "id": db["next"],
                    "from": frm,
                    "to": to,
                    "body": text[:8000],
                    "ts": time.time(),
                    "kind": str(body.get("kind", "text"))[:32],
                    "source": source,
                }
                if client_id:
                    message["client_id"] = client_id
                db["messages"].append(message)
                db["next"] += 1
                db["messages"] = db["messages"][-5000:]
                save(db)
            return self._send(200, message)

        if u.path == "/api/lines":
            lines = _line_list(body.get("lines"))
            if lines is None:
                return self._send(400, {"error": "lines must be a list"})
            with LOCK:
                db = load()
                db["lines"] = lines
                save(db)
            return self._send(200, {"ok": True})

        if u.path == "/clip":
            text = str(body.get("text", ""))
            source = str(body.get("source", "")).strip()[:32]
            with LOCK:
                db = load()
                cur = db.get("clip", {"text": "", "seq": 0, "source": ""})
                if text != cur.get("text", ""):
                    db["clip"] = {"text": text, "seq": _safe_int(cur.get("seq"), 0) + 1, "source": source}
                    save(db)
                    return self._send(200, db["clip"])
                return self._send(200, cur)

        if u.path == "/api/reset":
            with LOCK:
                old = load()
                db = _fresh_db()
                db["lines"] = old.get("lines", [])
                db["clip"] = old.get("clip", {"text": "", "seq": 0, "source": ""})
                save(db)
            return self._send(200, {"ok": True})

        return self._send(404, {"error": "not found"})


def main():
    port = int(os.environ.get("CARRIER_PORT", "8088"))
    ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()


if __name__ == "__main__":
    main()
