#!/usr/bin/env python3
"""A fake DevStride MCP server for scripts/tests/clearance-devstride.sh: the six claim tools over
HTTP on 127.0.0.1, with the claims kept in <state dir>/claims.json. Usage: fake-devstride.py
<state dir>; it writes its port to <state dir>/port once it listens and serves until killed.

Control files in the state dir (any may be absent):
  now        an ISO instant used as the server's clock (default: the real one)
  mode       unknown-tool | http403 | forbidden | redirect (a 307 to /followed, which marks the file `followed`) — every call answers that way (consumed by nothing)
  fail-once  the file's presence makes the next call answer HTTP 500, then removes it
  sse        its presence answers as text/event-stream instead of JSON
  version    text sent as the X-DevStride-Version response header
Expected credentials: headers must equal FAKE_DS_KEY / FAKE_DS_SECRET / FAKE_DS_ORG (defaults
test-key / test-secret / org-1). calls.log gets one line per call: tool, kind, key, the holder as
its digest, and any takeover digest — never a credential or a raw holder.
"""
import hashlib, json, os, sys
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = sys.argv[1]
KEY, SECRET, ORG = (os.environ.get("FAKE_DS_KEY", "test-key"), os.environ.get("FAKE_DS_SECRET", "test-secret"),
                    os.environ.get("FAKE_DS_ORG", "org-1"))


def control(name):
    try:
        with open(os.path.join(STATE, name)) as handle:
            return handle.read().strip()
    except OSError:
        return None


def now():
    forced = control("now")
    if forced:
        return datetime.fromisoformat(forced.replace("Z", "+00:00"))
    return datetime.now(timezone.utc).replace(microsecond=0)


def iso(value):
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def load():
    try:
        with open(os.path.join(STATE, "claims.json")) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def save(rows):
    with open(os.path.join(STATE, "claims.json"), "w") as handle:
        json.dump(rows, handle)


def digest(holder):
    return hashlib.sha256(holder.encode()).hexdigest()


def live(row):
    return row is not None and not row.get("releasedAt")


def expired(row):
    return datetime.fromisoformat(row["expiresAt"].replace("Z", "+00:00")) <= now()


def stamp(row, a, holder_digest=None):
    at = now()
    minutes = a.get("expiryMinutes") or 240
    if a.get("phase") and a["phase"] != row.get("phase"):
        row["phaseStartedAt"] = iso(at)
    for field in ("purpose", "phase", "payload"):
        if a.get(field) is not None:
            row[field] = a[field]
    row["heartbeatAt"] = iso(at)
    row["expiresAt"] = iso(at + timedelta(minutes=minutes))
    if holder_digest:
        row["holderDigest"] = holder_digest


def fresh(a):
    at = iso(now())
    row = {"kind": a["kind"], "key": a["key"], "holderDigest": digest(a["holder"]), "machine": a.get("machine"),
           "sessionName": a.get("sessionName"), "purpose": a.get("purpose"), "phase": a.get("phase"),
           "payload": a.get("payload"), "claimedAt": at, "heartbeatAt": at, "phaseStartedAt": at,
           "expiresAt": iso(now() + timedelta(minutes=a.get("expiryMinutes") or 240)), "releasedAt": None, "outcome": None}
    return row


def call(tool, a):
    rows = load()
    slot = "%s|%s" % (a.get("kind"), a.get("key"))
    row = rows.get(slot)
    me = digest(a["holder"]) if a.get("holder") else None
    if tool == "get_claim":
        return row if live(row) or (a.get("includeReleased") and row) else None
    if tool == "list_claims":
        return [r for r in rows.values() if live(r)]
    if tool == "claim_work":
        take = (a.get("takeover") or {}).get("expectedHolderDigest")
        if not live(row):
            rows[slot] = fresh(a); save(rows)
            return {"won": True, "expired": False, "final": False, "takenOver": False, "renewed": False, "claim": rows[slot]}
        if row["holderDigest"] == me:
            stamp(row, a); save(rows)
            return {"won": True, "expired": False, "final": False, "takenOver": False, "renewed": True, "claim": row}
        if expired(row) and take == row["holderDigest"]:
            rows[slot] = fresh(a); save(rows)
            return {"won": True, "expired": True, "final": False, "takenOver": True, "renewed": False, "claim": rows[slot]}
        return {"won": False, "expired": expired(row), "final": False, "takenOver": False, "renewed": False, "claim": row}
    if not live(row):
        return {"outcome": "NOT_HOLDER", "current": None}
    if tool == "heartbeat_claim":
        if row["holderDigest"] != me or expired(row):
            return {"outcome": "NOT_HOLDER", "current": row}
        stamp(row, a); save(rows)
        return row
    if tool == "release_claim":
        if row["holderDigest"] != me and not a.get("force"):
            return {"outcome": "NOT_HOLDER", "current": row}
        row["releasedAt"] = iso(now()); row["outcome"] = a.get("outcome")
        save(rows)
        return {"released": True, "claim": row}
    if tool == "adopt_claim":
        if row["holderDigest"] != a.get("expectedHolderDigest"):
            return {"outcome": "NOT_HOLDER", "current": row}
        row["machine"] = a.get("machine")
        stamp(row, dict(a, expiryMinutes=(a.get("expiryMinutes") or 20)), holder_digest=me)
        save(rows)
        return row
    raise KeyError(tool)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body, headers=None, kind="application/json"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        if control("version"):
            self.send_header("X-DevStride-Version", control("version"))
        self.end_headers()
        self.wfile.write(data)

    def rpc(self, result=None, error=None):
        message = {"jsonrpc": "2.0", "id": 1}
        message.update({"error": error} if error else {"result": result})
        if control("sse") is not None:
            return self.reply(200, "event: message\ndata: %s\n\n" % json.dumps(message), kind="text/event-stream")
        return self.reply(200, json.dumps(message))

    def text(self, text, is_error=False):
        return self.rpc({"content": [{"type": "text", "text": text}], "isError": is_error})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/followed":
            open(os.path.join(STATE, "followed"), "w").close()
            return self.reply(200, "{}")
        if self.path != "/mcp":
            return self.reply(404, "{}")
        if control("mode") == "redirect":
            self.send_response(307)
            self.send_header("Location", "/followed")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return None
        if (self.headers.get("X-DevStride-Api-Key"), self.headers.get("X-DevStride-Api-Secret"),
                self.headers.get("X-DevStride-Organization-Id")) != (KEY, SECRET, ORG):
            return self.reply(401, '{"message":"bad credentials"}')
        if os.path.exists(os.path.join(STATE, "fail-once")):
            os.remove(os.path.join(STATE, "fail-once"))
            return self.reply(500, "{}")
        mode = control("mode")
        tool = body["params"]["name"]
        args = body["params"].get("arguments") or {}
        with open(os.path.join(STATE, "calls.log"), "a") as handle:
            handle.write(json.dumps({"tool": tool, "kind": args.get("kind"), "key": args.get("key"),
                                     "holder": digest(args["holder"]) if args.get("holder") else None,
                                     "takeover": (args.get("takeover") or {}).get("expectedHolderDigest"),
                                     "expectedHolderDigest": args.get("expectedHolderDigest")}) + "\n")
        if mode == "http403":
            return self.reply(403, '{"message":"forbidden"}')
        if mode == "unknown-tool":
            return self.text("Unknown tool: %s" % tool, is_error=True)
        if mode == "forbidden":
            return self.text("Forbidden: missing permission MANAGE_AGENT_CLAIMS", is_error=True)
        try:
            data = call(tool, args)
        except KeyError:
            return self.text("Unknown tool: %s" % tool, is_error=True)
        return self.text(json.dumps({"data": data}))


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(STATE, "port"), "w") as handle:
    handle.write(str(server.server_port))
server.serve_forever()
