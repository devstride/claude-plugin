#!/bin/bash
# Tests for skills/run-workflow/scripts/library_skill.py — the fingerprint-checked cache of the
# organization's library skills. Every case runs the helper's own command line with XDG_CACHE_HOME
# pointed at a fresh temporary folder, so the real cache is never touched. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/run-workflow/scripts/library_skill.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

python3 - "$HELPER" "$T" <<'PY'
import ast, hashlib, json, os, subprocess, sys
helper, tmp = sys.argv[1], sys.argv[2]
FAIL = [0]
COUNTER = [0]

def check(name, ok, detail=""):
    print(("  ok   " if ok else "  FAIL ") + name + ("" if ok else " — " + detail))
    if not ok:
        FAIL[0] = 1

def fresh():
    COUNTER[0] += 1
    path = os.path.join(tmp, "c%d" % COUNTER[0])
    os.makedirs(path)
    return path

def call(cache, command, data, umask=None):
    env = dict(os.environ, XDG_CACHE_HOME=cache)
    argv = [sys.executable, helper] + ([command] if command else [])
    pre = (lambda: os.umask(umask)) if umask is not None else None
    p = subprocess.run(argv, input=data, capture_output=True, env=env, preexec_fn=pre)
    return p.returncode, p.stdout.decode(), p.stderr.decode()

def answer(out):
    return json.loads(out) if out.strip() else None

def h(data):
    return hashlib.sha256(data).hexdigest()

ORG = "org-aaa"
def manifest(body, name="tidy-review", version=1, implements="review@1", hsh=None):
    return {"name": name, "version": version, "hash": hsh or h(body), "implements": implements}

def put(cache, body, expect=None, answer_=None, org=ORG, extra=b"", umask=None):
    expect = expect or manifest(body)
    answer_ = answer_ if answer_ is not None else dict(expect)
    line = json.dumps({"organizationId": org, "expect": expect, "answer": answer_}).encode()
    return call(cache, "put", line + b"\n" + body + extra, umask)

def refused(name, result):
    code, out, err = result
    lines = err.strip().splitlines()
    good = code == 2 and out == "" and len(lines) == 1 and lines[0].startswith("library-skill: ") and "Traceback" not in err
    check(name, good, "code=%r out=%r err=%r" % (code, out, err))

def ask(cache, body, org=ORG, name="tidy-review", version=1, hsh=None):
    req = {"organizationId": org, "name": name, "version": version, "hash": hsh or h(body)}
    code, out, err = call(cache, "check", json.dumps(req).encode())
    return code, answer(out), err

# put, accepted
cases = [
    ("plain body", b"# Review\nCheck the diff.\n", b""),
    ("CRLF and byte-order mark kept byte for byte", b"\xef\xbb\xbf# Review\r\nLine two\r\n", b""),
    ("no trailing line feed, here-document adds one", b"# Review\nno newline at end", b"\n"),
    ("trailing line feed that is part of the fingerprint", b"# Review\nends with newline\n", b"\n"),
    ("multi-byte body", "# Revisión — 検査 ✓\n".encode("utf-8"), b""),
    ("exactly 65536 bytes", b"a" * 65536, b""),
]
for label, body, extra in cases:
    cache = fresh()
    code, out, err = put(cache, body, extra=extra)
    got = answer(out) if code == 0 else None
    stored = open(got["path"], "rb").read() if got else None
    check("put accepted: " + label, code == 0 and got["status"] == "stored" and stored == body and h(stored) == h(body)
          and got["size"] == len(body), "code=%r err=%r" % (code, err))

# put, refused
body = b"# Review\nCheck it.\n"
cache = fresh()
refused("put refused: body does not match expect.hash", put(cache, body + b"x", expect=manifest(body)))
other = dict(manifest(body)); other["hash"] = "0" * 64
refused("put refused: answer.hash differs from expect.hash", put(cache, body, answer_=other))
for field, value in (("name", "other-skill"), ("version", 2), ("implements", "risk@1")):
    a = dict(manifest(body)); a[field] = value
    refused("put refused: answer %s differs" % field, put(cache, body, answer_=a))
big = b"a" * 65537
refused("put refused: 65537 bytes", put(cache, big))
refused("put refused: a NUL byte", put(cache, b"ab\x00cd"))
refused("put refused: invalid UTF-8", put(cache, b"ab\xff\xfe"))
refused("put refused: an uppercase hash", put(cache, body, expect=manifest(body, hsh=h(body).upper())))
refused("put refused: a short hash", put(cache, body, expect=manifest(body, hsh="abc123")))
for org in ("../x", "a.b", "", "x" * 65):
    refused("put refused: organization id %r" % org[:12], put(cache, body, org=org))
for name in ("Bad_Name", "ab", "../x", "a/bc", "abc\x00d"):
    refused("put refused: name %r" % name, put(cache, body, expect=manifest(body, name=name)))
for version in (0, -1, 1.5, "1", True, 1000000001):
    refused("put refused: version %r" % (version,), put(cache, body, expect=manifest(body, version=version)))
refused("put refused: stdin not a JSON line", call(cache, "put", b"not json\nbody"))
refused("put refused: first line is a JSON array", call(cache, "put", b"[1,2]\nbody"))
refused("put refused: no body", call(cache, "put", json.dumps({"organizationId": ORG, "expect": manifest(body), "answer": manifest(body)}).encode()))
refused("refused: unknown command", call(cache, "fetch", b"{}"))
refused("refused: no command", call(cache, None, b"{}"))
check("nothing was written by any refused put", not os.path.exists(os.path.join(cache, "devstride-plugin", "skill-library", ORG)))

# check
cache = fresh()
code, got, _ = ask(cache, body)
check("check: empty cache is a miss (absent)", code == 0 and got == {"status": "miss", "reason": "absent"}, repr(got))
_, out, _ = put(cache, body)
path = answer(out)["path"]
code, got, _ = ask(cache, body)
check("check: hit after put with path and size", got == {"status": "hit", "path": path, "hash": h(body), "size": len(body)}, repr(got))
code, got2, _ = ask(cache, body)
check("check: a hit twice in a row", got2 == got, repr(got2))
with open(path, "r+b") as f:
    f.write(b"X")
code, got, _ = ask(cache, body)
check("check: a one-byte edit is a miss (corrupt, removed)", got == {"status": "miss", "reason": "corrupt", "removed": True}, repr(got))
check("check: both files are gone after a corrupt miss", not os.path.exists(path) and not os.path.exists(path[:-3] + ".json"))
code, out, _ = put(cache, body)
check("check: a following put restores the entry", code == 0 and ask(cache, body)[1]["status"] == "hit")
code, got, _ = ask(cache, body, hsh="1" * 64)
check("check: a wrong hash for a present entry is a miss (corrupt, removed)", got == {"status": "miss", "reason": "corrupt", "removed": True}, repr(got))
cache = fresh()
_, out, _ = put(cache, body)
a_path = answer(out)["path"]
code, got, _ = ask(cache, body, org="org-bbb")
check("check: organization B never sees organization A's entry", got == {"status": "miss", "reason": "absent"} and open(a_path, "rb").read() == body, repr(got))
body2 = b"# Review v2\n"
put(cache, body2, expect=manifest(body2, version=2))
check("check: two versions of one skill coexist", ask(cache, body)[1]["status"] == "hit" and ask(cache, body2, version=2)[1]["status"] == "hit")
refused("check refused: a hostile name", call(cache, "check", json.dumps({"organizationId": ORG, "name": "../x", "version": 1, "hash": h(body)}).encode()))

# list and remove
cache = fresh()
code, out, _ = call(cache, "list", b"{}")
check("list: a missing cache root answers empty", code == 0 and answer(out) == {"entries": [], "totalBytes": 0, "failing": 0}, out)
put(cache, body)
put(cache, body2, expect=manifest(body2, version=2))
b3 = b"# Other\n"
_, out, _ = put(cache, b3, expect=manifest(b3, name="other-skill"))
with open(answer(out)["path"], "ab") as f:
    f.write(b"!")
got = answer(call(cache, "list", b"{}")[1])
check("list: entries, total bytes and the failing count", len(got["entries"]) == 3 and got["failing"] == 1
      and got["totalBytes"] == len(body) + len(body2) + len(b3) + 1, repr(got))
meta = os.path.join(cache, "devstride-plugin", "skill-library", ORG, "tidy-review", "2.json")
os.unlink(meta)
got = answer(call(cache, "list", json.dumps({"organizationId": ORG}).encode())[1])
invalid = [e for e in got["entries"] if e["name"] == "tidy-review" and e["version"] == 2]
check("list: an entry without its metadata is invalid", invalid and invalid[0]["valid"] is False, repr(got))
code, out, _ = call(cache, "remove", json.dumps({"organizationId": ORG, "name": "tidy-review", "version": 1}).encode())
check("remove: deletes exactly one version", answer(out) == {"removed": True} and ask(cache, body)[1]["status"] == "miss"
      and os.path.exists(os.path.join(cache, "devstride-plugin", "skill-library", ORG, "tidy-review", "2.md")), out)
code, out, _ = call(cache, "remove", json.dumps({"organizationId": ORG, "name": "tidy-review", "version": 9}).encode())
check("remove: an absent entry reports removed false", answer(out) == {"removed": False}, out)

# filesystem safety
cache = fresh()
_, out, err = put(cache, body, umask=0)
p = answer(out)["path"]
folder = os.path.dirname(p)
modes = [oct(os.stat(x).st_mode & 0o777) for x in (folder, os.path.dirname(folder), os.path.dirname(os.path.dirname(folder)))]
check("safety: folders are 0700 under umask 000", modes == ["0o700"] * 3, repr(modes))
fmodes = [oct(os.stat(x).st_mode & 0o777) for x in (p, p[:-3] + ".json")]
check("safety: files are 0600 under umask 000", fmodes == ["0o600"] * 2, repr(fmodes))
check("safety: no temporary sibling left behind", sorted(os.listdir(folder)) == ["1.json", "1.md"], repr(os.listdir(folder)))
open(os.path.join(folder, ".1.md.999.tmp"), "wb").write(b"junk")
got = answer(call(cache, "list", b"{}")[1])
check("safety: a stale temporary file is not an entry", len(got["entries"]) == 1, repr(got))
elsewhere = os.path.join(tmp, "elsewhere"); os.makedirs(elsewhere, exist_ok=True)
import shutil
shutil.rmtree(folder); os.symlink(elsewhere, folder)
refused("safety: put refuses a symbolic-link entry folder", put(cache, body))
refused("safety: check refuses a symbolic-link entry folder", call(cache, "check", json.dumps({"organizationId": ORG, "name": "tidy-review", "version": 1, "hash": h(body)}).encode()))
check("safety: nothing was written through the link", os.listdir(elsewhere) == [])
cache = fresh()
os.makedirs(os.path.join(cache, "devstride-plugin"))
os.symlink(elsewhere, os.path.join(cache, "devstride-plugin", "skill-library"))
refused("safety: a cache root that is a symbolic link is refused", put(cache, body))

# static check: standard library only, no network modules
tree = ast.parse(open(helper).read())
names = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        names.update(a.name.split(".")[0] for a in node.names)
    elif isinstance(node, ast.ImportFrom):
        names.add((node.module or "").split(".")[0])
banned = {"urllib", "http", "socket", "ssl", "requests", "ftplib", "smtplib", "xmlrpc", "asyncio"}
allowed = {"hashlib", "json", "os", "re", "sys", "time"}
check("static: no network module and nothing outside the standard library", not (names & banned) and names <= allowed, repr(sorted(names)))

sys.exit(FAIL[0])
PY
STATUS=$?
[ "$STATUS" -eq 0 ] && echo "library-skill: all passed" || echo "library-skill: FAILED"
exit "$STATUS"
